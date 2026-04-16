import ballerina/file;
import ballerina/io;
import ballerina/lang.regexp;

function setupMockServerModule(string connectorPath, boolean quietMode = false) returns error? {
    string ballerinaDir = connectorPath + "/ballerina";
    string mockServerModuleDir = ballerinaDir + "/modules/mock.server";
    // cd into ballerina dir and add mock.server module using bal add cmd

    if !quietMode {
        io:println("Setting up mock.server module...");
    }

    boolean moduleExists = check file:test(mockServerModuleDir, file:EXISTS);
    if !moduleExists {
        string command = string `bal add mock.server`;

        CommandResult addResult = executeCommand(command, ballerinaDir, quietMode);
        if !addResult.success {
            return error("Failed to add mock.server module" + addResult.stderr);
        }

        if !quietMode {
            io:println("✓ Mock.server module added successfully");
        }
    } else if !quietMode {
        io:println("✓ mock.server module already exists; reusing existing module");
    }

    // delete the auto generated tests directory
    string mockTestDir = ballerinaDir + "/modules/mock.server/tests";
    if check file:test(mockTestDir, file:EXISTS) {
        check file:remove(mockTestDir, file:RECURSIVE);
        if !quietMode {
            io:println("Removed auto generated tests directory");
        }
    }

    // delete auto generated mock.server.bal file
    string mockServerFile = ballerinaDir + "/modules/mock.server/mock.server.bal";
    if check file:test(mockServerFile, file:EXISTS) {
        check file:remove(mockServerFile, file:RECURSIVE);
        if !quietMode {
            io:println("Removed auto generated mock.server.bal file");
        }
    }

    return;
}

function generateMockServer(string connectorPath, string specPath, boolean quietMode = false) returns error? {
    string ballerinaDir = connectorPath + "/ballerina";
    string mockServerDir = ballerinaDir + "/modules/mock.server";

    if isBallerinaApiSpec(specPath) {
        check generateMockServerFromBallerinaSpec(ballerinaDir, mockServerDir, specPath, quietMode);
        return;
    }

    int operationCount = check countOperationsInSpec(specPath);
    if !quietMode {
        io:println(string `Total operations found in spec: ${operationCount}`);
    }

    string command;

    if operationCount <= MAX_OPERATIONS {
        if !quietMode {
            io:println(string `Using all ${operationCount} operations`);
        }
        command = string `bal openapi -i ${specPath} -o ${mockServerDir}`;
    } else {
        if !quietMode {
            io:println(string `Filtering from ${operationCount} to ${MAX_OPERATIONS} most useful operations`);
        }
        string operationsList = check selectOperationsUsingAI(specPath);
        if !quietMode {
            io:println(string `Selected operations: ${operationsList}`);
        }
        command = string `bal openapi -i ${specPath} -o ${mockServerDir} --operations ${operationsList}`;
    }

    // generate mock service template using openapi tool
    CommandResult result = executeCommand(command, ballerinaDir, quietMode);
    if !result.success {
        return error("Failed to generate mock server using ballerina openAPI tool" + result.stderr);
    }

    // rename mock server
    string mockServerPathOld = mockServerDir + "/aligned_ballerina_openapi_service.bal";
    string mockServerPathNew = mockServerDir + "/mock_server.bal";
    if check file:test(mockServerPathOld, file:EXISTS) {
        check file:rename(mockServerPathOld, mockServerPathNew);
        if !quietMode {
            io:println("Renamed mock server file");
        }
    }

    // delete client.bal
    string clientPath = mockServerDir + "/client.bal";
    if check file:test(clientPath, file:EXISTS) {
        check file:remove(clientPath, file:RECURSIVE);
        if !quietMode {
            io:println("Removed client.bal");
        }
    }

    return;
}

function generateMockServerFromBallerinaSpec(string ballerinaDir, string mockServerDir, string specPath,
        boolean quietMode = false) returns error? {
    string specContent = check io:fileReadString(specPath);
    string[] operationIds = extractRemoteOperationIdsFromBallerinaSpec(specContent);

    if !quietMode {
        io:println(string `Total operations found in spec: ${operationIds.length()}`);
        io:println(string `Using all ${operationIds.length()} operations`);
    }

    string[] lines = [
        "import ballerina/http;",
        "",
        "listener http:Listener ep0 = new (9090);",
        "",
        "service /v1 on ep0 {"
    ];

    if operationIds.length() == 0 {
        lines.push("    resource function get health() returns json {");
        lines.push("        return {\"status\": \"ok\"};");
        lines.push("    }");
    } else {
        foreach string operationId in operationIds {
            string accessor = inferHttpAccessor(operationId);
            lines.push(string `    # Mock endpoint for ${operationId}`);
            lines.push(string `    resource function ${accessor} ${operationId}() returns json|http:Response {`);
            lines.push(string `        return {"operation": "${operationId}", "status": "mocked"};`);
            lines.push("    }");
        }
    }

    lines.push("}");

    string mockServerPath = mockServerDir + "/mock_server.bal";
    check io:fileWriteString(mockServerPath, string:'join("\n", ...lines));

    string sourceTypesPath = ballerinaDir + "/types.bal";
    string targetTypesPath = mockServerDir + "/types.bal";
    if check file:test(sourceTypesPath, file:EXISTS) {
        string typesContent = check io:fileReadString(sourceTypesPath);
        check io:fileWriteString(targetTypesPath, typesContent);
    }
}

function countOperationsInSpec(string specPath) returns int|error {
    string specContent = check io:fileReadString(specPath);

    if isBallerinaApiSpec(specPath) || specContent.includes("public isolated client class Client {") {
        return extractRemoteOperationIdsFromBallerinaSpec(specContent).length();
    }

    // count operationId occurences in the spec
    regexp:RegExp operationIdPattern = re `"operationId"\s*:\s*"[^"]*"`;
    regexp:Span[] matches = operationIdPattern.findAll(specContent);
    return matches.length();

}

function isBallerinaApiSpec(string specPath) returns boolean {
    return specPath.toLowerAscii().endsWith(".bal");
}

function extractRemoteOperationIdsFromBallerinaSpec(string specContent) returns string[] {
    string[] operationIds = [];
    string[] lines = regexp:split(re `\n`, specContent);

    foreach string line in lines {
        string trimmed = line.trim();
        if !trimmed.startsWith("remote isolated function ") {
            continue;
        }

        int startIndex = 25;
        int? paren = trimmed.indexOf("(");
        if paren is int && <int>paren > startIndex {
            string operationId = trimmed.substring(startIndex, <int>paren).trim();
            if operationId.length() > 0 {
                operationIds.push(operationId);
            }
        }
    }

    return operationIds;
}

function inferHttpAccessor(string operationId) returns string {
    string lower = operationId.toLowerAscii();
    if lower.startsWith("get") || lower.startsWith("list") || lower.startsWith("head") {
        return "get";
    }
    if lower.startsWith("delete") || lower.startsWith("remove") {
        return "delete";
    }
    if lower.startsWith("update") || lower.startsWith("put") {
        return "put";
    }
    if lower.startsWith("patch") {
        return "patch";
    }
    return "post";
}
