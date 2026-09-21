package com.yahoo.yscb.db.neo4j;

/**
 * Neo4j connection configuration.
 */
public class Neo4jConfig {
  private final String url;
  private final String username;
  private final String password;

  public Neo4jConfig(String url, String username, String password) {
    this.url = url;
    this.username = username;
    this.password = password;
  }

  public String url() {
    return url;
  }

  public String username() {
    return username;
  }

  public String password() {
    return password;
  }
}
