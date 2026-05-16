// Slim 模式 mongo-init：把 mongo1 拉成单成员 RS（RS-of-1）
// 后续想升级到 3 成员，把 mongo-ha profile 起来后手动跑：
//   rs.add("mongo2:27017"); rs.add("mongo3:27017")

const RS_NAME = "rs0";

function waitForPrimary(maxSec) {
  const start = Date.now();
  while ((Date.now() - start) / 1000 < maxSec) {
    try {
      const s = rs.status();
      const primary = s.members.find(m => m.stateStr === "PRIMARY");
      if (primary) {
        print("primary ready: " + primary.name);
        return primary;
      }
    } catch (e) {}
    sleep(2000);
  }
  throw new Error("timeout waiting for primary");
}

try {
  rs.conf();
  print("rs already initiated, leave it alone");
} catch (e) {
  print("initiating single-node RS " + RS_NAME);
  printjson(rs.initiate({
    _id: RS_NAME,
    members: [{ _id: 0, host: "mongo1:27017", priority: 1 }]
  }));
}

waitForPrimary(60);

const ADMIN = db.getSiblingDB("admin");
function upsertUser(user, pwd, roles) {
  try {
    ADMIN.createUser({ user, pwd, roles });
    print("created user: " + user);
  } catch (e) {
    if (e.codeName === "DuplicateKey" || (e.message && e.message.includes("already exists"))) {
      ADMIN.updateUser(user, { pwd, roles });
      print("updated user: " + user);
    } else {
      throw e;
    }
  }
}

upsertUser("root", "root123", [{ role: "root", db: "admin" }]);
upsertUser("app_rw", "apprw123", [{ role: "readWriteAnyDatabase", db: "admin" }]);
upsertUser("app_ro", "appro123", [{ role: "readAnyDatabase", db: "admin" }]);
upsertUser("exporter", "exporter123", [
  { role: "clusterMonitor", db: "admin" },
  { role: "read", db: "local" }
]);

print("mongo-init (lite) done");
