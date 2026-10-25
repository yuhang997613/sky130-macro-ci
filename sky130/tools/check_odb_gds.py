import odb

print("odb ok")
print([m for m in dir(odb.dbDatabase) if "GDS" in m or "gds" in m][:20])
print([m for m in dir(odb) if "write" in m.lower()][:20])
