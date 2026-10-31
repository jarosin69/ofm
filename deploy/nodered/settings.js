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

// Loads a library that is built into the OFM Node-RED image (nodered/Dockerfile)
// so function nodes can use it. Returns undefined if it is missing.
function builtIn(name) {
    try {
        return require(require.resolve(name, { paths: [
            process.cwd(),
            "/usr/src/node-red/node_modules",
            "/usr/src/node-red/node_modules/node-red",          // libraries that come with Node-RED itself
            "/usr/src/node-red/node_modules/@node-red/nodes"
        ] }));
    } catch (e) {
        console.warn("[ofm] library not available to function nodes: " + name);
        return undefined;
    }
}

// Compares two strings in constant time, so response timing reveals nothing.
function sameText(a, b) {
    const hash = (s) => crypto.createHash("sha256").update(String(s)).digest();
    return crypto.timingSafeEqual(hash(a), hash(b));
}

const admin = { username: adminUser, permissions: "*" };

module.exports = {
    uiPort: process.env.PORT || 1880,

    // OFM's flows are code (ADR-0016): the flow file lives in the repository
    // (flows/ofm-runtime.json, mounted at /ofm/flows) and Deploy writes there.
    // Set by FLOWS in docker-compose.yml; the official image passes FLOWS to
    // Node-RED on the command line, which takes precedence over this line.
    flowFile: process.env.FLOWS || "flows.json",
    flowFilePretty: true,            // one property per line: readable Git diffs

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

    // Function nodes may not install npm modules on their own; libraries are
    // built into the image and handed over here, at pinned versions.
    functionExternalModules: false,
    functionGlobalContext: {
        opcua: builtIn("node-opcua"),               // OPC UA acquisition (ADR-0017)
        s7: builtIn("@st-one-io/nodes7"),           // Siemens S7 acquisition (ADR-0018)
        ethernetip: builtIn("st-ethernet-ip"),      // Rockwell EtherNet/IP acquisition (ADR-0018)
        pg: builtIn("pg"),                          // model change listener (ADR-0001); comes with node-red-contrib-postgresql
        mqtt: builtIn("mqtt"),                      // start-up clean-up of stale topics (ADR-0004); comes with Node-RED
        fs: require("fs"),                          // historian store-and-forward queue (ADR-0002); Node.js itself
        path: require("path"),
        zlib: require("zlib")
    },

    editorTheme: {
        projects: { enabled: false }
    },

    logging: {
        console: { level: "info", metrics: false, audit: false }
    }
};
