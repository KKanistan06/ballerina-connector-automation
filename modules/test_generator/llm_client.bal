import ballerina/file;
import ballerina/http;
import ballerina/io;
import ballerina/os;

configurable string testGenModel = "claude-sonnet-4-6";
configurable int testGenMaxTokens = 32000;

type CommandResult record {|
    boolean success;
    string stdout;
    string stderr;
|};

function initAIService(boolean quietMode = true) returns error? {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey is string && apiKey.length() > 0 {
        return;
    }

    if !quietMode {
        io:println("ANTHROPIC_API_KEY environment variable is required for AI-powered generation");
    }
    return error("ANTHROPIC_API_KEY environment variable not set");
}

function callAI(string prompt) returns string|error {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey is () || apiKey.length() == 0 {
        return error("ANTHROPIC_API_KEY environment variable not set");
    }

    http:Client anthropicClient = check new ("https://api.anthropic.com", {
        timeout: 1000
    });

    map<json> bodyMap = {
        "model": testGenModel,
        "max_tokens": testGenMaxTokens,
        "temperature": 0.0d,
        "messages": [
            {
                "role": "user",
                "content": prompt
            }
        ]
    };

    map<string> headers = {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01"
    };

    http:Response response = check anthropicClient->post("/v1/messages", bodyMap, headers);
    if response.statusCode != 200 {
        string|error responseText = response.getTextPayload();
        if responseText is string {
            return error(string `Anthropic API error: ${response.statusCode} - ${responseText}`);
        }
        return error(string `Anthropic API error: ${response.statusCode}`);
    }

    json responseBody = check response.getJsonPayload();
    json|error contentArray = responseBody.content;
    if contentArray is json && contentArray is json[] {
        foreach json block in <json[]>contentArray {
            json|error blockType = block.'type;
            json|error textField = block.text;
            if blockType is json && blockType.toString() == "text" && textField is json {
                string|error castResult = textField.ensureType(string);
                return castResult is string ? castResult : textField.toString();
            }
        }
    }

    return error("No text block found in Anthropic response");
}

function executeCommand(string command, string workingDir, boolean quietMode = true) returns CommandResult {
    string stdoutFile = ".test_generator.stdout.log";
    string stderrFile = ".test_generator.stderr.log";
    string stdoutPath = string `${workingDir}/${stdoutFile}`;
    string stderrPath = string `${workingDir}/${stderrFile}`;

    string fullCommand = string `cd "${workingDir}" && ${command} > "${stdoutFile}" 2> "${stderrFile}"`;

    os:Process|error process = os:exec({
                                           value: "bash",
                                           arguments: ["-c", fullCommand]
                                       });

    if process is error {
        return {
            success: false,
            stdout: "",
            stderr: process.message()
        };
    }

    int|error exitCodeResult = process.waitForExit();
    if exitCodeResult is error {
        return {
            success: false,
            stdout: "",
            stderr: exitCodeResult.message()
        };
    }

    string stdout = "";
    string|io:Error stdoutRead = io:fileReadString(stdoutPath);
    if stdoutRead is string {
        stdout = stdoutRead;
    }

    string stderr = "";
    string|io:Error stderrRead = io:fileReadString(stderrPath);
    if stderrRead is string {
        stderr = stderrRead;
    }

    cleanupCommandLogs(stdoutPath, stderrPath);

    if !quietMode && <int>exitCodeResult != 0 {
        io:println(string `Command failed: ${command}`);
    }

    return {
        success: <int>exitCodeResult == 0,
        stdout: stdout,
        stderr: stderr
    };
}

function cleanupCommandLogs(string stdoutPath, string stderrPath) {
    boolean|error stdoutExists = file:test(stdoutPath, file:EXISTS);
    if stdoutExists is boolean && stdoutExists {
        if file:remove(stdoutPath) is error {
        }
    }

    boolean|error stderrExists = file:test(stderrPath, file:EXISTS);
    if stderrExists is boolean && stderrExists {
        if file:remove(stderrPath) is error {
        }
    }
}
