const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const Database = require("better-sqlite3");

const MIN_PASSWORD_LENGTH = 8;

const hashPassword = (password) => {
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = crypto.scryptSync(password, salt, 64).toString("hex");
  return `scrypt:${salt}:${hash}`;
};

const verifyPassword = (password, encoded) => {
  const parts = String(encoded || "").split(":");
  if (parts.length !== 3 || parts[0] !== "scrypt") return false;
  const salt = parts[1];
  const expectedHash = parts[2];
  const actualHash = crypto.scryptSync(password, salt, 64).toString("hex");
  if (expectedHash.length !== actualHash.length) return false;
  return crypto.timingSafeEqual(Buffer.from(actualHash), Buffer.from(expectedHash));
};

const validateNewPassword = (password) => {
  if (typeof password !== "string" || password.length < MIN_PASSWORD_LENGTH) {
    throw new Error(`senha deve ter ao menos ${MIN_PASSWORD_LENGTH} caracteres`);
  }
};

const openAuthStore = (dbPath) => {
  const fullDbPath = path.resolve(dbPath);
  fs.mkdirSync(path.dirname(fullDbPath), { recursive: true });

  const db = new Database(fullDbPath);
  db.pragma("journal_mode = WAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'admin',
      active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  `);

  const findUserStmt = db.prepare(`
    SELECT id, username, password_hash, role, active, created_at, updated_at
    FROM users
    WHERE username = ?
    LIMIT 1
  `);

  const insertUserStmt = db.prepare(`
    INSERT INTO users (username, password_hash, role, active)
    VALUES (?, ?, ?, 1)
  `);

  const updatePasswordStmt = db.prepare(`
    UPDATE users
    SET password_hash = ?, updated_at = datetime('now')
    WHERE username = ?
  `);

  const getPublicUsersStmt = db.prepare(`
    SELECT username, role, active, created_at, updated_at
    FROM users
    ORDER BY username ASC
  `);

  const findUser = (username) => findUserStmt.get(String(username || "").trim());

  const ensureUser = (username, password, role = "admin") => {
    const cleanUsername = String(username || "").trim();
    if (!cleanUsername) throw new Error("username obrigatorio");
    validateNewPassword(String(password || ""));

    const existing = findUser(cleanUsername);
    if (existing) return existing;

    insertUserStmt.run(cleanUsername, hashPassword(password), role);
    return findUser(cleanUsername);
  };

  const validateCredentials = (username, password) => {
    const user = findUser(username);
    if (!user || Number(user.active) !== 1) return null;
    if (!verifyPassword(String(password || ""), user.password_hash)) return null;
    return user;
  };

  const changePassword = (username, currentPassword, newPassword) => {
    const user = findUser(username);
    if (!user || Number(user.active) !== 1) {
      throw new Error("usuario nao encontrado");
    }
    if (!verifyPassword(String(currentPassword || ""), user.password_hash)) {
      throw new Error("senha atual invalida");
    }
    validateNewPassword(String(newPassword || ""));
    updatePasswordStmt.run(hashPassword(newPassword), user.username);
    return findUser(user.username);
  };

  const listUsers = () =>
    getPublicUsersStmt.all().map((row) => ({
      username: row.username,
      role: row.role,
      active: Boolean(row.active),
      created_at: row.created_at,
      updated_at: row.updated_at
    }));

  return {
    dbPath: fullDbPath,
    ensureUser,
    validateCredentials,
    changePassword,
    listUsers
  };
};

module.exports = {
  MIN_PASSWORD_LENGTH,
  openAuthStore
};
