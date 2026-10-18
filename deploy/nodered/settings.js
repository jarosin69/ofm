/**
 * OFM Node-RED settings, mounted read-only into the container from
 * deploy/nodered/settings.js. Secrets come from environment variables set in
 * deploy/.env, never from this file. Settings not listed here use Node-RED's
 * defaults.
 */
const crypto = require("crypto");

const adminUser = process.env.NODERED_ADMIN_USER || "admin";
const adminPassword = process.env.NODERED_ADMIN_PASSWORD;
const credentialSecret = process.env.NODE_RED_CREDENTIAL_SECRET;

// Refuse to start rather than run an unprotected editor (Architecture Overview §13).
if (!adminPassword) throw new Error("NODERED_ADMIN_PASSWORD is not set in deploy/.env");
if (!credentialSecret) throw new Error("NODE_RED_CREDENTIAL_SECRET is not set in deploy/.env");

// Compares two strings in constant time, so response timing reveals nothing.
function sameText(a, b) {
    const hash = (s) => crypto.createHash("sha256").update(String(s)).digest();
    return crypto.timingSafeEqual(hash(a), hash(b));
}

const admin = { username: adminUser, permissions: "*" };

module.exports = {
    uiPort: process.env.PORT || 1880,
    flowFile: "flows.json",
    flowFilePretty: true,            // readable diffs when flows are exported to flows/

    // Encrypts credentials in flows_cred.json. Never change once set.
    credentialSecret: credentialSecret,

    // Editor login, checked against NODERED_ADMIN_PASSWORD from deploy/.env.
    // This protects the editor and admin API only; operator dashboards get
    // their own protection when they are built (Phase 3a).
    adminAuth: {
        type: "credentials",
        users: (username) => Promise.resolve(username === adminUser ? admin : null),
        authenticate: (username, password) =>
            Promise.resolve(username === adminUser && sameText(password, adminPassword) ? admin : null)
    },

    // Function nodes may not install npm modules on their own; dependencies are
    // added deliberately through the palette.
    functionExternalModules: false,

    editorTheme: {
        projects: { enabled: false }
    },

    logging: {
        console: { level: "info", metrics: false, audit: false }
    }
};
