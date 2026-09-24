package com.yahoo.yscb.db.neo4j;

import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.Driver;
import org.neo4j.driver.GraphDatabase;
import org.neo4j.driver.Result;
import org.neo4j.driver.Session;
import org.neo4j.driver.Values;

import site.ycsb.ByteIterator;
import site.ycsb.Status;
import site.ycsb.StringByteIterator;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.Vector;

/**
 * Helper for Neo4j CRUD operations.
 */
public class Neo4jConnection {
  private final Driver driver;
  private final Session session;

  public Neo4jConnection(Neo4jConfig config) {
    driver = GraphDatabase.driver(
        config.url(),
        AuthTokens.basic(config.username(), config.password())
    );

    driver.verifyConnectivity();

    session = driver.session();
  }

  public void close() {
    session.close();
    driver.close();
  }

  public Status insert(String table, String key, Map<String, ByteIterator> values) {
    try {
      Map<String, Object> props = new HashMap<>();
      values.forEach((k, v) -> props.put(k, v.toString()));

      // Use CREATE to ensure new nodes are created
      // The unique constraint will prevent duplicates and throw an error if a duplicate key is attempted
      // This is the correct behavior for insert operations - they should create new records
      Result result = session.run(
          "CREATE (n:" + table + " {id: $key}) SET n += $props",
          Values.parameters("key", key, "props", props)
      );

      result.consume();

      return Status.OK;
    } catch (org.neo4j.driver.exceptions.ClientException e) {
      // If it's a constraint violation (duplicate key), return ERROR
      // This is the expected behavior for insert - duplicate keys should fail
      String message = e.getMessage();
      if (message != null && (message.contains("already exists") || message.contains("constraint"))) {
        System.err.println("Duplicate key detected during insert: " + key);
        return Status.ERROR;
      }
      System.err.println("Error inserting into Neo4j: " + e.getMessage());
      e.printStackTrace();
      return Status.ERROR;
    } catch (Exception e) {
      System.err.println("Error inserting into Neo4j: " + e.getMessage());
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  public Status read(String table, String key, Set<String> fields,
                     Map<String, ByteIterator> result) {
    try {
      Result queryResult = session.run(
          "MATCH (n:" + table + " {id: $key}) RETURN n",
          Values.parameters("key", key)
      );

      if (!queryResult.hasNext()) {
        queryResult.consume();
        return Status.NOT_FOUND;
      }

      // Use single() to verify unique constraint is working
      // If constraint is properly enforced, there should be exactly one node with this id
      org.neo4j.driver.types.Node node = queryResult.single().get("n").asNode();

      // If fields is null, return all properties; otherwise return only requested fields
      if (fields == null) {
        // Return all properties except 'id'
        for (Map.Entry<String, Object> entry : node.asMap().entrySet()) {
          if (!"id".equals(entry.getKey())) {
            result.put(entry.getKey(), new StringByteIterator(String.valueOf(entry.getValue())));
          }
        }
      } else {
        // Return only requested fields
        // IMPORTANT: For extend operations, we must return all requested fields,
        // even if they don't exist yet (return empty string for missing fields)
        for (String field : fields) {
          if (node.containsKey(field)) {
            try {
              org.neo4j.driver.Value value = node.get(field);
              if (value.isNull()) {
                result.put(field, new StringByteIterator(""));
              } else {
                result.put(field, new StringByteIterator(value.asString()));
              }
            } catch (Exception e) {
              // If we can't get the value, return empty string
              result.put(field, new StringByteIterator(""));
            }
          } else {
            // Field doesn't exist yet - return empty string for extend operations
            result.put(field, new StringByteIterator(""));
          }
        }
      }

      queryResult.consume();

      return Status.OK;

    } catch (Exception e) {
      System.err.println("Error reading from Neo4j: " + e.getMessage());
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  public Status update(String table, String key, Map<String, ByteIterator> values) {
    try {
      Map<String, Object> props = new HashMap<>();
      values.forEach((k, v) -> props.put(k, v.toString()));

      Result result = session.run(
          "MATCH (n:" + table + " {id: $key}) SET n += $props",
          Values.parameters("key", key, "props", props)
      );

      result.consume();

      return Status.OK;
    } catch (Exception e) {
      System.err.println("Error updating Neo4j: " + e.getMessage());
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  /**
   * Appends to one property inside the database.
   *
   * <p>One Cypher statement does the whole read-modify-write, so the value being grown
   * never travels to the client. The CASE reproduces {@code DB.extend}'s rule exactly -
   * append only while the property stays under {@code maxfieldlength}, otherwise write it
   * back unchanged - and the increment length and the limit are constants in the query,
   * leaving just the key and the increment as parameters. Properties hold strings (that is
   * what {@link #insert} and {@link #update} store), so {@code +} concatenates them.
   *
   * @return OK when a node was written, NOT_FOUND when no node has that id
   */
  public Status extend(String table, String key, String field, String appendValue, long maxfieldlength) {
    try {
      Result result = session.run(
          "MATCH (n:" + table + " {id: $key}) SET n." + field + " = CASE"
              + " WHEN size(coalesce(n." + field + ", '')) + " + appendValue.length()
              + " < " + maxfieldlength
              + " THEN coalesce(n." + field + ", '') + $append"
              + " ELSE n." + field + " END RETURN n.id AS id",
          Values.parameters("key", key, "append", appendValue)
      );

      // The RETURN only produces a row when a node with that id was matched.
      boolean extended = result.hasNext();
      result.consume();

      return extended ? Status.OK : Status.NOT_FOUND;
    } catch (Exception e) {
      System.err.println("Error extending Neo4j node: " + e.getMessage());
      e.printStackTrace();
      return Status.ERROR;
    }
  }

  public Status delete(String table, String key) {
    try {
      Result result = session.run(
          "MATCH (n:" + table + " {id: $key}) DETACH DELETE n",
          Values.parameters("key", key)
      );

      result.consume();

      return Status.OK;
    } catch (Exception e) {
      return Status.ERROR;
    }
  }

  public Status scan(String table, String startKey, int recordCount, Set<String> fields,
                     Vector<HashMap<String, ByteIterator>> result) {
    try {
      Result queryResult = session.run(
          "MATCH (n:" + table + ") "
              + "WHERE n.id >= $startKey "
              + "RETURN n ORDER BY n.id LIMIT $limit",
          Values.parameters("startKey", startKey, "limit", recordCount)
      );

      while (queryResult.hasNext()) {
        org.neo4j.driver.types.Node node = queryResult.next().get("n").asNode();
        HashMap<String, ByteIterator> map = new HashMap<String, ByteIterator>();
        for (Map.Entry<String, Object> entry : node.asMap().entrySet()) {
          map.put(entry.getKey(), new StringByteIterator(String.valueOf(entry.getValue())));
        }
        result.add(map);
      }

      queryResult.consume();

      return Status.OK;

    } catch (Exception e) {
      return Status.ERROR;
    }
  }
}
