package com.yahoo.yscb.db.neo4j;

import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;
import site.ycsb.ByteIterator;

import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.Vector;

/**
 * YCSB client binding for Neo4j.
 */
public class Neo4jClient extends DB {

  private Neo4jConnection conn;
  private Neo4jConfig config;

  /** True (default) to append inside the database, false to use DB.extend(). */
  private boolean extendServerSide;

  @Override
  public void init() throws DBException {
    Properties props = getProperties();

    String url = props.getProperty("url");
    String username = props.getProperty("username");
    String password = props.getProperty("password");

    extendServerSide = isServerSideExtend(props);
    config = new Neo4jConfig(url, username, password);
    conn = new Neo4jConnection(config);
  }

  @Override
  public void cleanup() throws DBException {
    if (conn != null) {
      conn.close();
    }
  }

  @Override
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result) {
    try {
      return conn.read(table, key, fields, result);
    } catch (Exception e) {
      return Status.ERROR;
    }
  }

  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values) {
    try {
      return conn.update(table, key, values);
    } catch (Exception e) {
      return Status.ERROR;
    }
  }

  /**
   * Extend one field of a node.
   *
   * <p>Two implementations, selected by {@code -p extend.serverside} (default
   * {@code true}):
   * <ul>
   * <li><b>server side</b> - one Cypher statement appends inside Neo4j, so the value
   * being grown never reaches the client.</li>
   * <li><b>client side</b> - {@link DB#extend(String, String, Map, long)}: read,
   * concatenate here, write the whole property back.</li>
   * </ul>
   * Both append if and only if {@code len(current) + len(append) < maxfieldlength},
   * so they leave identical data.
   */
  @Override
  public Status extend(String table, String key, Map<String, ByteIterator> values, long maxfieldlength) {
    if (values == null || values.isEmpty()) {
      return Status.BAD_REQUEST;
    }

    if (!extendServerSide) {
      // Client-side extend: read/concatenate/update through the generic interface.
      return super.extend(table, key, values, maxfieldlength);
    }

    try {
      Map.Entry<String, ByteIterator> entry = values.entrySet().iterator().next();
      String appendValue = entry.getValue() == null ? "" : entry.getValue().toString();
      return conn.extend(table, key, entry.getKey(), appendValue, maxfieldlength);
    } catch (Exception e) {
      return Status.ERROR;
    }
  }

  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values) {
    try {
      return conn.insert(table, key, values);
    } catch (Exception e) {
      return Status.ERROR;
    }
  }

  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields,
                     Vector<HashMap<String, ByteIterator>> result) {
    try {
      return conn.scan(table, startkey, recordcount, fields, result);
    } catch (Exception e) {
      return Status.ERROR;
    }
  }

  @Override
  public Status delete(String table, String key) {
    try {
      return conn.delete(table, key);
    } catch (Exception e) {
      return Status.ERROR;
    }
  }
}
