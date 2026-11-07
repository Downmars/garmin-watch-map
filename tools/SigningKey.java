import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.KeyPairGenerator;

class SigningKey {
    public static void main(String[] args) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(4096);
        Files.write(Path.of(args[0]), generator.generateKeyPair().getPrivate().getEncoded(),
                    StandardOpenOption.CREATE_NEW);
    }
}
