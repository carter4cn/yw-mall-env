// mongo-init 一次性脚本
// 通过 mongosh 跑：先 rs.initiate（幂等），再创建业务用户。
// 由 mongo-init 容器调用：mongosh --host mongo1:27017 --quiet < init-replset.js

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
    } catch (e) {
      // 集群可能还没 initiate，忽略
    }
    sleep(2000);
  }
  throw new Error("timeout waiting for primary");
}

// 1) 初始化 RS（幂等）
try {
  const cfg = rs.conf();
  print("rs already initiated, current version=" + cfg.version);
} catch (e) {
  print("initiating replica set " + RS_NAME);
  const r = rs.initiate({
    _id: RS_NAME,
    members: [
      { _id: 0, host: "mongo1:27017", priority: 2 },
      { _id: 1, host: "mongo2:27017", priority: 1 },
      { _id: 2, host: "mongo3:27017", priority: 1 }
    ]
  });
  printjson(r);
}

waitForPrimary(60);

// 2) 切到 primary（mongosh 自动跟随 RS topology）
// 创建用户：root / app_rw / app_ro / backup / exporter / pbm
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

// 注：keyFile + auth 模式下，第一次 createUser 之前 localhost exception 允许无鉴权
// 之后所有连接都需要带凭据 — mongo-init 用 MONGO_INITDB_ROOT_USERNAME/PASSWORD 自动带

upsertUser("root", "root123", [{ role: "root", db: "admin" }]);

upsertUser("app_rw", "apprw123", [
  { role: "readWriteAnyDatabase", db: "admin" }
]);

upsertUser("app_ro", "appro123", [
  { role: "readAnyDatabase", db: "admin" }
]);

upsertUser("backup", "backup123", [
  { role: "backup", db: "admin" },
  { role: "restore", db: "admin" },
  { role: "clusterMonitor", db: "admin" }
]);

upsertUser("exporter", "exporter123", [
  { role: "clusterMonitor", db: "admin" },
  { role: "read", db: "local" }
]);

// PBM 专用 — Percona 官方文档定义的最小权限集
// https://docs.percona.com/percona-backup-mongodb/install/initial-setup.html
const PBM_ROLE = "pbmAnyAction";
try {
  ADMIN.createRole({
    role: PBM_ROLE,
    privileges: [{ resource: { anyResource: true }, actions: ["anyAction"] }],
    roles: []
  });
} catch (e) {
  print("pbm role exists or other: " + e.message);
}

upsertUser("pbm", "pbm123", [
  { role: "readWrite", db: "admin" },
  { role: "backup", db: "admin" },
  { role: "restore", db: "admin" },
  { role: "clusterMonitor", db: "admin" },
  { role: PBM_ROLE, db: "admin" }
]);

print("mongo-init done");
