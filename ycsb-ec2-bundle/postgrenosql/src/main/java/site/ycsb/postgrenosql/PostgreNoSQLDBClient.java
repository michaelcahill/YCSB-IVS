/*
 * Copyright 2017 YCSB Contributors. All Rights Reserved.
 *
 * CODE IS BASED ON the jdbc-binding JdbcDBClient class.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you
 * may not use this file except in compliance with the License. You
 * may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * permissions and limitations under the License. See accompanying
 * LICENSE file.
 */
package site.ycsb.postgrenosql;

import site.ycsb.*;
import org.json.simple.JSONObject;
import org.postgresql.Driver;
import org.postgresql.util.PGobject;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicInteger;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;

/**
 * PostgreNoSQL client for YCSB framework.
 */
public class PostgreNoSQLDBClient extends DB {
  private static final Logger LOG = LoggerFactory.getLogger(PostgreNoSQLDBClient.class);

  /** Count the number of times initialized to teardown on the last. */
  private static final AtomicInteger INIT_COUNT = new AtomicInteger(0);

  /** Cache for already prepared statements. */
  private static ConcurrentMap<StatementType, PreparedStatement> cachedStatements;

  /** The driver to get the connection to postgresql. */
  private static Driver postgrenosqlDriver;

  /** The connection to the database. */
  private static Connection connection;

  /** The class to use as the jdbc driver. */
  public static final String DRIVER_CLASS = "db.driver";

  /** The URL to connect to the database. */
  public static final String CONNECTION_URL = "postgrenosql.url";

  /** The user name to use to connect to the database. */
  public static final String CONNECTION_USER = "postgrenosql.user";

  /** The password to use for establishing the connection. */
  public static final String CONNECTION_PASSWD = "postgrenosql.passwd";

  /** The JDBC connection auto-commit property for the driver. */
  public static final String JDBC_AUTO_COMMIT = "postgrenosql.autocommit";

  /** The primary key in the user table. */
  public static final String PRIMARY_KEY = "YCSB_KEY";

  /** The field name prefix in the table. */
  public static final String COLUMN_NAME = "YCSB_VALUE";

  /** True (default) to append inside PostgreSQL, false to use DB.extend(). */
  private boolean extendServerSide;

  private static final String DEFAULT_PROP = "";

  /** Returns parsed boolean value from the properties if set, otherwise returns defaultVal. */
  private static boolean getBoolProperty(Properties props, String key, boolean defaultVal) {
    String valueStr = props.getProperty(key);
    if (valueStr != null) {
      return Boolean.parseBoolean(valueStr);
    }
    return defaultVal;
  }

  @Override
  public void init() throws DBException {
    INIT_COUNT.incrementAndGet();
    // Read before the early return below: the shared driver is set up once, but every
    // client instance needs its own copy of the extend mode.
    this.extendServerSide = getBoolProperty(getProperties(), EXTEND_SERVER_SIDE_PROPERTY,
        EXTEND_SERVER_SIDE_PROPERTY_DEFAULT);
    synchronized (PostgreNoSQLDBClient.class) {
      if (postgrenosqlDriver != null) {
        return;
      }

      Properties props = getProperties();
      String urls = props.getProperty(CONNECTION_URL, DEFAULT_PROP);
      String user = props.getProperty(CONNECTION_USER, DEFAULT_PROP);
      String passwd = props.getProperty(CONNECTION_PASSWD, DEFAULT_PROP);
      boolean autoCommit = getBoolProperty(props, JDBC_AUTO_COMMIT, true);

      try {
        Properties tmpProps = new Properties();
        tmpProps.setProperty("user", user);
        tmpProps.setProperty("password", passwd);

        cachedStatements = new ConcurrentHashMap<>();

        postgrenosqlDriver = new Driver();
        connection = postgrenosqlDriver.connect(urls, tmpProps);
        connection.setAutoCommit(autoCommit);

      } catch (Exception e) {
        LOG.error("Error during initialization: " + e);
      }
    }
  }

  @Override
  public void cleanup() throws DBException {
    if (INIT_COUNT.decrementAndGet() == 0) {
      try {
        cachedStatements.clear();

        if (!connection.getAutoCommit()){
          connection.commit();
        }
        connection.close();
      } catch (SQLException e) {
        System.err.println("Error in cleanup execution. " + e);
      }
      postgrenosqlDriver = null;
    }
  }

  @Override
  public Status read(String tableName, String key, Set<String> fields, Map<String, ByteIterator> result) {
    try {
      StatementType type = new StatementType(StatementType.Type.READ, tableName, fields);
      PreparedStatement readStatement = cachedStatements.get(type);
      if (readStatement == null) {
        readStatement = createAndCacheReadStatement(type);
      }
      readStatement.setString(1, key);
      ResultSet resultSet = readStatement.executeQuery();
      if (!resultSet.next()) {
        resultSet.close();
        return  Status.NOT_FOUND;
      }

      if (result != null) {
        if (fields == null){
          do{
            String field = resultSet.getString(2);
            String value = resultSet.getString(3);
            result.put(field, new StringByteIterator(value));
          }while (resultSet.next());
        } else {
          for (String field : fields) {
            String value = resultSet.getString(field);
            result.put(field, new StringByteIterator(value));
          }
        }
      }
      resultSet.close();
      return Status.OK;

    } catch (SQLException e) {
      LOG.error("Error in processing read of table " + tableName + ": " + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status scan(String tableName, String startKey, int recordcount, Set<String> fields,
                     Vector<HashMap<String, ByteIterator>> result) {
    try {
      StatementType type = new StatementType(StatementType.Type.SCAN, tableName, fields);
      PreparedStatement scanStatement = cachedStatements.get(type);
      if (scanStatement == null) {
        scanStatement = createAndCacheScanStatement(type);
      }
      scanStatement.setString(1, startKey);
      scanStatement.setInt(2, recordcount);
      ResultSet resultSet = scanStatement.executeQuery();
      for (int i = 0; i < recordcount && resultSet.next(); i++) {
        if (result != null && fields != null) {
          HashMap<String, ByteIterator> values = new HashMap<String, ByteIterator>();
          for (String field : fields) {
            String value = resultSet.getString(field);
            values.put(field, new StringByteIterator(value));
          }

          result.add(values);
        }
      }

      resultSet.close();
      return Status.OK;
    } catch (SQLException e) {
      LOG.error("Error in processing scan of table: " + tableName + ": " + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status update(String tableName, String key, Map<String, ByteIterator> values) {
    try{
      StatementType type = new StatementType(StatementType.Type.UPDATE, tableName, null);
      PreparedStatement updateStatement = cachedStatements.get(type);
      if (updateStatement == null) {
        updateStatement = createAndCacheUpdateStatement(type);
      }

      JSONObject jsonObject = new JSONObject();
      for (Map.Entry<String, ByteIterator> entry : values.entrySet()) {
        jsonObject.put(entry.getKey(), entry.getValue().toString());
      }

      PGobject object = new PGobject();
      object.setType("jsonb");
      object.setValue(jsonObject.toJSONString());

      updateStatement.setObject(1, object);
      updateStatement.setString(2, key);

      int result = updateStatement.executeUpdate();
      if (result == 1) {
        return Status.OK;
      }
      return Status.UNEXPECTED_STATE;
    } catch (SQLException e) {
      LOG.error("Error in processing update to table: " + tableName + e);
      return Status.ERROR;
    }
  }

  /**
   * Extend one field of a document.
   *
   * <p>Two implementations, selected by {@code -p extend.serverside} (default
   * {@code true}):
   * <ul>
   * <li><b>server side</b> - one UPDATE with {@code jsonb_set} appends to the
   * attribute inside PostgreSQL, so the field being grown never leaves the server.</li>
   * <li><b>client side</b> - {@link DB#extend(String, String, Map, long)}: read,
   * concatenate here, write the whole document back.</li>
   * </ul>
   * Both append if and only if {@code len(current) + len(append) < maxfieldlength},
   * so they leave identical data; a field at or over the limit is rewritten unchanged
   * ({@code OK}) and only a missing key gives {@code NOT_FOUND}.
   *
   * <p>Values are JSON strings in the {@code YCSB_VALUE} column (that is what
   * {@link #update(String, String, Map)} writes), so text concatenation with {@code ||}
   * is all the pushdown needs. The column is declared {@code NOT NULL} by this binding's
   * schema; a document that lacks the field grows an empty string.
   */
  @Override
  public Status extend(String tableName, String key, Map<String, ByteIterator> values, long maxfieldlength) {
    if (values == null || values.isEmpty()) {
      return Status.BAD_REQUEST;
    }

    if (!extendServerSide) {
      // Client-side extend: read/concatenate/update through the generic interface.
      return super.extend(tableName, key, values, maxfieldlength);
    }

    Map.Entry<String, ByteIterator> entry = values.entrySet().iterator().next();
    String field = entry.getKey();
    String appendValue = entry.getValue() == null ? "" : entry.getValue().toString();

    // The increment length and the limit are constants here, so they go into the
    // statement as literals and only the increment and the key are parameters.
    String currentJson = COLUMN_NAME + "->>'" + field + "'";
    String sql = "UPDATE " + tableName + " SET " + COLUMN_NAME + " = jsonb_set(" + COLUMN_NAME
        + ", '{" + field + "}', to_jsonb(CASE"
        + " WHEN length(coalesce(" + currentJson + ", '')) + " + appendValue.length()
        + " < " + maxfieldlength
        + " THEN coalesce(" + currentJson + ", '') || COALESCE(?, '')"
        + " ELSE coalesce(" + currentJson + ", '') END), true)"
        + " WHERE " + PRIMARY_KEY + " = ?";

    try (PreparedStatement extendStatement = connection.prepareStatement(sql)) {
      extendStatement.setString(1, appendValue);
      extendStatement.setString(2, key);
      int result = extendStatement.executeUpdate();
      if (result == 1) {
        return Status.OK;
      }
      return Status.NOT_FOUND;
    } catch (SQLException e) {
      LOG.error("Error in processing extend of table " + tableName + ": " + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status insert(String tableName, String key, Map<String, ByteIterator> values) {
    try{
      StatementType type = new StatementType(StatementType.Type.INSERT, tableName, null);
      PreparedStatement insertStatement = cachedStatements.get(type);
      if (insertStatement == null) {
        insertStatement = createAndCacheInsertStatement(type);
      }

      JSONObject jsonObject = new JSONObject();
      for (Map.Entry<String, ByteIterator> entry : values.entrySet()) {
        jsonObject.put(entry.getKey(), entry.getValue().toString());
      }

      PGobject object = new PGobject();
      object.setType("jsonb");
      object.setValue(jsonObject.toJSONString());

      insertStatement.setObject(2, object);
      insertStatement.setString(1, key);

      int result = insertStatement.executeUpdate();
      if (result == 1) {
        return Status.OK;
      }

      return Status.UNEXPECTED_STATE;
    } catch (SQLException e) {
      LOG.error("Error in processing insert to table: " + tableName + ": " + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status delete(String tableName, String key) {
    try{
      StatementType type = new StatementType(StatementType.Type.DELETE, tableName, null);
      PreparedStatement deleteStatement = cachedStatements.get(type);
      if (deleteStatement == null) {
        deleteStatement = createAndCacheDeleteStatement(type);
      }
      deleteStatement.setString(1, key);

      int result = deleteStatement.executeUpdate();
      if (result == 1){
        return Status.OK;
      }

      return Status.UNEXPECTED_STATE;
    } catch (SQLException e) {
      LOG.error("Error in processing delete to table: " + tableName + e);
      return Status.ERROR;
    }
  }

  private PreparedStatement createAndCacheReadStatement(StatementType readType)
      throws SQLException{
    PreparedStatement readStatement = connection.prepareStatement(createReadStatement(readType));
    PreparedStatement statement = cachedStatements.putIfAbsent(readType, readStatement);
    if (statement == null) {
      return readStatement;
    }
    return statement;
  }

  private String createReadStatement(StatementType readType){
    StringBuilder read = new StringBuilder("SELECT " + PRIMARY_KEY + " AS " + PRIMARY_KEY);

    if (readType.getFields() == null) {
      read.append(", (jsonb_each_text(" + COLUMN_NAME + ")).*");
    } else {
      for (String field:readType.getFields()){
        read.append(", " + COLUMN_NAME + "->>'" + field + "' AS " + field);
      }
    }

    read.append(" FROM " + readType.getTableName());
    read.append(" WHERE ");
    read.append(PRIMARY_KEY);
    read.append(" = ");
    read.append("?");
    return read.toString();
  }

  private PreparedStatement createAndCacheScanStatement(StatementType scanType)
      throws SQLException{
    PreparedStatement scanStatement = connection.prepareStatement(createScanStatement(scanType));
    PreparedStatement statement = cachedStatements.putIfAbsent(scanType, scanStatement);
    if (statement == null) {
      return scanStatement;
    }
    return statement;
  }

  private String createScanStatement(StatementType scanType){
    StringBuilder scan = new StringBuilder("SELECT " + PRIMARY_KEY + " AS " + PRIMARY_KEY);
    if (scanType.getFields() != null){
      for (String field:scanType.getFields()){
        scan.append(", " + COLUMN_NAME + "->>'" + field + "' AS " + field);
      }
    }
    scan.append(" FROM " + scanType.getTableName());
    scan.append(" WHERE ");
    scan.append(PRIMARY_KEY);
    scan.append(" >= ?");
    scan.append(" ORDER BY ");
    scan.append(PRIMARY_KEY);
    scan.append(" LIMIT ?");

    return scan.toString();
  }

  public PreparedStatement createAndCacheUpdateStatement(StatementType updateType)
      throws SQLException{
    PreparedStatement updateStatement = connection.prepareStatement(createUpdateStatement(updateType));
    PreparedStatement statement = cachedStatements.putIfAbsent(updateType, updateStatement);
    if (statement == null) {
      return updateStatement;
    }
    return statement;
  }

  private String createUpdateStatement(StatementType updateType){
    StringBuilder update = new StringBuilder("UPDATE ");
    update.append(updateType.getTableName());
    update.append(" SET ");
    update.append(COLUMN_NAME + " = " + COLUMN_NAME);
    update.append(" || ? ");
    update.append(" WHERE ");
    update.append(PRIMARY_KEY);
    update.append(" = ?");
    return update.toString();
  }

  private PreparedStatement createAndCacheInsertStatement(StatementType insertType)
      throws SQLException{
    PreparedStatement insertStatement = connection.prepareStatement(createInsertStatement(insertType));
    PreparedStatement statement = cachedStatements.putIfAbsent(insertType, insertStatement);
    if (statement == null) {
      return insertStatement;
    }
    return statement;
  }

  private String createInsertStatement(StatementType insertType){
    StringBuilder insert = new StringBuilder("INSERT INTO ");
    insert.append(insertType.getTableName());
    insert.append(" (" + PRIMARY_KEY + "," + COLUMN_NAME + ")");
    insert.append(" VALUES(?,?)");
    return insert.toString();
  }

  private PreparedStatement createAndCacheDeleteStatement(StatementType deleteType)
      throws SQLException{
    PreparedStatement deleteStatement = connection.prepareStatement(createDeleteStatement(deleteType));
    PreparedStatement statement = cachedStatements.putIfAbsent(deleteType, deleteStatement);
    if (statement == null) {
      return deleteStatement;
    }
    return statement;
  }

  private String createDeleteStatement(StatementType deleteType){
    StringBuilder delete = new StringBuilder("DELETE FROM ");
    delete.append(deleteType.getTableName());
    delete.append(" WHERE ");
    delete.append(PRIMARY_KEY);
    delete.append(" = ?");
    return delete.toString();
  }
}
