/**
 * Copyright (c) 2010-2016 Yahoo! Inc., 2017 YCSB contributors All rights reserved.
 * <p>
 * Licensed under the Apache License, Version 2.0 (the "License"); you
 * may not use this file except in compliance with the License. You
 * may obtain a copy of the License at
 * <p>
 * http://www.apache.org/licenses/LICENSE-2.0
 * <p>
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * permissions and limitations under the License. See accompanying
 * LICENSE file.
 */

package site.ycsb;

import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.Vector;

/**
 * A layer for accessing a database to be benchmarked. Each thread in the client
 * will be given its own instance of whatever DB class is to be used in the test.
 * This class should be constructed using a no-argument constructor, so we can
 * load it dynamically. Any argument-based initialization should be
 * done by init().
 *
 * Note that YCSB does not make any use of the return codes returned by this class.
 * Instead, it keeps a count of the return values and presents them to the user.
 *
 * The semantics of methods such as insert, update and delete vary from database
 * to database.  In particular, operations may or may not be durable once these
 * methods commit, and some systems may return 'success' regardless of whether
 * or not a tuple with a matching key existed before the call.  Rather than dictate
 * the exact semantics of these methods, we recommend you either implement them
 * to match the database's default semantics, or the semantics of your 
 * target application.  For the sake of comparison between experiments we also 
 * recommend you explain the semantics you chose when presenting performance results.
 */
public abstract class DB {
  /**
   * Selects which extend() implementation a binding uses. {@code true} (the
   * default) lets the binding push the append down into the datastore, if it
   * knows how; {@code false} forces the client-side implementation defined by
   * {@link #extend(String, String, Map, long)}.
   */
  public static final String EXTEND_SERVER_SIDE_PROPERTY = "extend.serverside";

  /**
   * Default for {@link #EXTEND_SERVER_SIDE_PROPERTY}: bindings use their
   * server-side extend when they have one.
   */
  public static final boolean EXTEND_SERVER_SIDE_PROPERTY_DEFAULT = true;

  /**
   * Reads {@link #EXTEND_SERVER_SIDE_PROPERTY} for the benefit of bindings that
   * have no boolean property helper of their own.
   *
   * @param p The DB properties
   * @return true when the binding should push extends into the datastore
   */
  protected static boolean isServerSideExtend(Properties p) {
    return Boolean.parseBoolean(p.getProperty(EXTEND_SERVER_SIDE_PROPERTY,
        Boolean.toString(EXTEND_SERVER_SIDE_PROPERTY_DEFAULT)));
  }

  /**
   * Properties for configuring this DB.
   */
  private Properties properties = new Properties();

  /**
   * Set the properties for this DB.
   */
  public void setProperties(Properties p) {
    properties = p;

  }

  /**
   * Get the set of properties for this DB.
   */
  public Properties getProperties() {
    return properties;
  }

  /**
   * Initialize any state for this DB.
   * Called once per DB instance; there is one DB instance per client thread.
   */
  public void init() throws DBException {
  }

  /**
   * Cleanup any state for this DB.
   * Called once per DB instance; there is one DB instance per client thread.
   */
  public void cleanup() throws DBException {
  }

  /**
   * Read a record from the database. Each field/value pair from the result will be stored in a HashMap.
   *
   * @param table The name of the table
   * @param key The record key of the record to read.
   * @param fields The list of fields to read, or null for all of them
   * @param result A HashMap of field/value pairs for the result
   * @return The result of the operation.
   */
  public abstract Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result);

  /**
   * Perform a range scan for a set of records in the database. Each field/value pair from the result will be stored
   * in a HashMap.
   *
   * @param table The name of the table
   * @param startkey The record key of the first record to read.
   * @param recordcount The number of records to read
   * @param fields The list of fields to read, or null for all of them
   * @param result A Vector of HashMaps, where each HashMap is a set field/value pairs for one record
   * @return The result of the operation.
   */
  public abstract Status scan(String table, String startkey, int recordcount, Set<String> fields,
                              Vector<HashMap<String, ByteIterator>> result);

  /**
   * Update a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key, overwriting any existing values with the same field name.
   *
   * @param table The name of the table
   * @param key The record key of the record to write.
   * @param values A HashMap of field/value pairs to update in the record
   * @return The result of the operation.
   */
  public abstract Status update(String table, String key, Map<String, ByteIterator> values);

  /**
   * Extend fields in the database: append the given value to what the field
   * already holds, as long as the field stays below {@code maxfieldlength}.
   *
   * <p>This is the <em>client-side</em> implementation of the operation - it
   * reads the field, concatenates in the client and writes the whole value back,
   * so the current value crosses the wire twice. Bindings that can append inside
   * the datastore override this method; they are expected to keep the rule below
   * (append if and only if {@code len(current) + len(append) < maxfieldlength},
   * never truncate) so both implementations leave identical data, and honour
   * {@link #EXTEND_SERVER_SIDE_PROPERTY} to let the caller pick which one runs.
   *
   * @param table The name of the table
   * @param key The record key of the record to write.
   * @param values A HashMap of field/value pairs to update in the record
   * @param maxfieldlength Append only while the field stays below this length;
   *                       a non positive value means never append (matching the
   *                       comparison above)
   * @return The result of the operation.
   */
  public Status extend(String table, String key, Map<String, ByteIterator> values, long maxfieldlength) {
    HashMap<String, ByteIterator> result = new HashMap<String, ByteIterator>();
    Set<String> fields = values.keySet();

    Status status = read(table, key, fields, result);
    if (status == Status.OK) {
      for (String fieldkey : fields) {
        String orig = result.get(fieldkey).toString();
        String incr = values.get(fieldkey).toString();
        if (orig.length() + incr.length() < maxfieldlength) {
          result.put(fieldkey, new StringByteIterator(orig + incr));
        }
      }
      status = update(table, key, result);
    }

    return status;
  }

  /**
   * Insert a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key.
   *
   * @param table The name of the table
   * @param key The record key of the record to insert.
   * @param values A HashMap of field/value pairs to insert in the record
   * @return The result of the operation.
   */
  public abstract Status insert(String table, String key, Map<String, ByteIterator> values);

  /**
   * Delete a record from the database.
   *
   * @param table The name of the table
   * @param key The record key of the record to delete.
   * @return The result of the operation.
   */
  public abstract Status delete(String table, String key);
}
