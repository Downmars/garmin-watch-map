"""Thread-safe network byte counts shared by the preview and offline maker."""
from collections import deque
import threading
import time


class DownloadCancelled(Exception):
    pass


def byte_size(value):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if value < 1024 or unit == 'GB':
            return f'{value:.1f} {unit}'
        value /= 1024


class DownloadProgress:
    def __init__(self, total=0, clock=time.monotonic):
        self.total = total
        self.clock = clock
        self.started = clock()
        self.lock = threading.Lock()
        self.cancelled = threading.Event()
        self.samples = deque()
        self.received = 0
        self.completed = set()
        self.cached = set()
        self.failures = 0
        self.stage = '准备下载'

    def request(self):
        self.check_cancelled()
        self.set_stage('等待服务器响应')

    def cancel(self):
        self.cancelled.set()

    def check_cancelled(self):
        if self.cancelled.is_set():
            raise DownloadCancelled()

    def add_bytes(self, count):
        with self.lock:
            self.received += count
            self.samples.append((self.clock(), count))
            self.stage = '正在下载'

    def complete(self, key, cached=False):
        with self.lock:
            if key not in self.completed:
                self.completed.add(key)
                if cached:
                    self.cached.add(key)
            self.stage = '处理地图'

    def retry(self):
        with self.lock:
            self.failures += 1
            self.stage = '等待重试'

    def set_stage(self, stage):
        with self.lock:
            self.stage = stage

    def snapshot(self):
        with self.lock:
            now = self.clock()
            while self.samples and self.samples[0][0] <= now-3:
                self.samples.popleft()
            elapsed = max(0, now-self.started)
            speed = sum(count for _,count in self.samples)/max(.25,min(3,elapsed))
            return dict(stage=self.stage, received=self.received, speed=speed,
                        completed=len(self.completed), cached=len(self.cached),
                        total=self.total, failures=self.failures, elapsed=elapsed)

    def text(self):
        info = self.snapshot()
        text = (f"{info['stage']} · {byte_size(info['speed'])}/s（近3秒）"
                f" · 已接收 {byte_size(info['received'])}"
                f" · 瓦片 {info['completed']}/{info['total']} · 缓存 {info['cached']}"
                f" · 用时 {int(info['elapsed'])} 秒")
        if info['failures']:
            text += f" · 失败尝试 {info['failures']} 次"
        return text


def read_tile(response, transfer=None):
    """Read bounded image bytes, reporting actual response data as it arrives."""
    chunks = []
    total = 0
    read = getattr(response, 'read1', response.read)
    while True:
        if transfer is not None:
            transfer.check_cancelled()
        chunk = read(min(16*1024, 4*1024*1024+1-total))
        if not chunk:
            break
        total += len(chunk)
        if transfer is not None:
            transfer.add_bytes(len(chunk))
        if total > 4*1024*1024:
            raise ValueError('瓦片超过 4 MB，请选择普通 256px 图片')
        chunks.append(chunk)
    return b''.join(chunks)
