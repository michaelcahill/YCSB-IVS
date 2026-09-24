# Neo4j binding

## Extend operation (`extend.serverside`)

`extend` appends a value to one property of a node, up to the `maxfieldlength` cap. Two
implementations:

```sh
extend.serverside=true        # default: append inside Neo4j
extend.serverside=false       # client side: DB.extend() - read, concatenate here, update
```

The server-side implementation (default) does the whole read-modify-write in one Cypher
statement, so the property being grown never reaches the client:

```cypher
MATCH (n:usertable {id: $key})
   SET n.field1 = CASE WHEN size(coalesce(n.field1, '')) + <append length> < <maxfieldlength>
                       THEN coalesce(n.field1, '') + $append
                       ELSE n.field1 END
 RETURN n.id AS id
```

Both implementations append if and only if `len(current) + len(append) < maxfieldlength`, so
they leave identical data: a property at or over the limit is rewritten unchanged (`OK`), and
only a missing node gives `NOT_FOUND` (the `RETURN` yields no row). Properties hold strings,
which is what makes `+` enough here. Verified against Neo4j 5.26 in both modes.
