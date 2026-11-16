package app;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.util.Map;
import org.eclipse.microprofile.config.inject.ConfigProperty;

/**
 * Golden-path Quarkus service (koorikla/platform templates/java-quarkus-service): JSON API, health and version
 * endpoints. Replace the resources with your own; keep /healthz (the platform's probes and smoke tests use it).
 */
@Path("/")
@Produces(MediaType.APPLICATION_JSON)
public class GreetingResource {

    @ConfigProperty(name = "app.greeting")
    String greeting;

    @ConfigProperty(name = "app.version")
    String version;

    @ConfigProperty(name = "HOSTNAME", defaultValue = "unknown")
    String hostname;

    public record Greeting(String message, String hostname, String version) {}

    @GET
    public Greeting root() {
        return new Greeting(greeting, hostname, version);
    }

    @GET
    @Path("healthz")
    public Map<String, String> healthz() {
        return Map.of("status", "ok");
    }

    @GET
    @Path("version")
    public Map<String, String> version() {
        return Map.of("version", version);
    }
}
