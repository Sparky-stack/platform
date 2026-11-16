package app;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.notNullValue;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

@QuarkusTest
class GreetingResourceTest {

    @Test
    void rootReturnsGreeting() {
        given().when().get("/").then()
                .statusCode(200)
                .body("message", equalTo("tere"))
                .body("version", equalTo("abc1234"))
                .body("hostname", notNullValue());
    }

    @Test
    void healthzIsOk() {
        given().when().get("/healthz").then().statusCode(200).body("status", equalTo("ok"));
    }

    @Test
    void versionIsReported() {
        given().when().get("/version").then().statusCode(200).body("version", equalTo("abc1234"));
    }

    @Test
    void quarkusHealthIsUp() {
        given().when().get("/q/health/ready").then().statusCode(200).body("status", equalTo("UP"));
    }

    @Test
    void unknownRouteIs404() {
        given().when().get("/nope").then().statusCode(404);
    }
}
