import ballerina/io;
import ballerina/lang.'string as strings;
import ballerina/lang.regexp;

import wso2/connector_automation.code_fixer;

const int MAX_OPERATIONS = 60;

function generateTestFile(string connectorPath, string[]? operationIds = (), boolean quietMode = false) returns error? {
    // Analyze connector artifacts for live-test generation
    ConnectorAnalysis analysis = check analyzeConnectorForTests(connectorPath, operationIds);

    // Generate test content using AI
    string testContent = sanitizeGeneratedCode(check generateTestsWithAI(analysis));
    testContent = normalizeGeneratedLiveTests(testContent);

    // Strip unsafe patterns: enum-based attributeNames args and computed enum map keys
    testContent = stripUnsafeEnumPatterns(testContent);

    // Write test file
    string testFilePath = connectorPath + "/ballerina/tests/test.bal";
    check io:fileWriteString(testFilePath, testContent);

    if !quietMode {
        io:println("✓ Test file generated successfully");
        io:println(string `  Output: ${testFilePath}`);
    }
    return;
}

// ---------------------------------------------------------------------------
// Strip patterns that cause native adapter failures at runtime:
// 1. attributeNames = [...] optional parameters with enum members
// 2. [ENUM_MEMBER]: "value" computed map key syntax
// ---------------------------------------------------------------------------

function stripUnsafeEnumPatterns(string content) returns string {
    string[] lines = regexp:split(re `\n`, content);
    string[] out = [];
    int i = 0;
    while i < lines.length() {
        string line = lines[i];
        string trimmed = line.trim();

        // Remove standalone attributeNames = [...] lines (single or multi-line)
        if trimmed.startsWith("attributeNames = [") || trimmed.startsWith("attributeNames=[") {
            if trimmed.includes("]") {
                i += 1;
                continue;
            }
            i += 1;
            while i < lines.length() {
                if lines[i].includes("]") {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Remove inline attributeNames = [...] from method call lines
        if line.includes("attributeNames = [") && line.includes("]") {
            int? atStart = line.indexOf("attributeNames = [");
            if atStart is int {
                int? atEnd = line.indexOf("]", atStart);
                if atEnd is int {
                    string before = line.substring(0, atStart).trim();
                    string after = line.substring(atEnd + 1);
                    if before.endsWith(",") {
                        before = before.substring(0, before.length() - 1);
                    }
                    string afterTrimmed = after.trim();
                    if afterTrimmed.startsWith(",") {
                        int? commaIdx = after.indexOf(",");
                        if commaIdx is int {
                            after = after.substring(commaIdx + 1);
                        }
                    }
                    string merged = before + after;
                    if merged.trim().length() > 0 {
                        out.push(merged);
                    }
                    i += 1;
                    continue;
                }
            }
        }

        // Remove computed enum map key lines: [ENUM_MEMBER]: "value"
        if trimmed.startsWith("[") && trimmed.includes("]:") {
            int? closeBracket = trimmed.indexOf("]:");
            if closeBracket is int {
                string insideBrackets = trimmed.substring(1, closeBracket).trim();
                boolean isIdentifier = insideBrackets.length() > 0 && !insideBrackets.startsWith("\"");
                if isIdentifier {
                    i += 1;
                    continue;
                }
            }
        }

        out.push(line);
        i += 1;
    }
    return string:'join("\n", ...out);
}

function normalizeGeneratedLiveTests(string content) returns string {
    string[] lines = regexp:split(re `\n`, content);
    string[] out = [];

    int i = 0;
    while i < lines.length() {
        string line = lines[i];
        string trimmed = line.trim();

        // 1) Convert missing-env getClient() error to skip sentinel.
        if trimmed.startsWith("return error(\"Required environment variables") {
            string ws = getLeadingWhitespaceFromLine(line);
            out.push(string `${ws}return error("LIVE_TEST_DISABLED: required environment variables are not set");`);
            i += 1;
            continue;
        }

        // 2) Replace silent pass block:
        // if clientResult is error {
        //     return;
        // }
        if trimmed == "if clientResult is error {" && i + 2 < lines.length() {
            string nextTrimmed = lines[i + 1].trim();
            string nextNextTrimmed = lines[i + 2].trim();
            if nextTrimmed == "return;" && nextNextTrimmed == "}" {
                string ws = getLeadingWhitespaceFromLine(line);
                out.push(string `${ws}if clientResult is error {`);
                out.push(string `${ws}    if clientResult.message().startsWith("LIVE_TEST_DISABLED:") {`);
                out.push(string `${ws}        return;`);
                out.push(string `${ws}    }`);
                out.push(string `${ws}    return clientResult;`);
                out.push(string `${ws}}`);
                i += 3;
                continue;
            }
        }

        // 3) Rewrite tautological assertion pattern:
        // test:assertTrue((var is string) && (<string>var).length() > 0, ...)
        if trimmed.startsWith("test:assertTrue((") && trimmed.includes(" is string) && (<string>") &&
            trimmed.includes(").length() > 0,") {
            int? prefixIndex = line.indexOf("test:assertTrue((");
            if prefixIndex is int {
                int varStart = <int>prefixIndex + 17;
                int? varEnd = line.indexOf(" is string) && (<string>", varStart);
                if varEnd is int {
                    string variable = line.substring(varStart, <int>varEnd);
                    string assertPrefix = line.substring(0, <int>prefixIndex);
                    int? msgStart = line.indexOf(",", <int>varEnd);
                    if msgStart is int {
                        string remainder = line.substring(<int>msgStart);
                        out.push(string `${assertPrefix}test:assertTrue((${variable} ?: "").length() > 0${remainder}`);
                        i += 1;
                        continue;
                    }
                }
            }
        }

        out.push(line);
        i += 1;
    }

    return string:'join("\n", ...out);
}

function getLeadingWhitespaceFromLine(string line) returns string {
    int idx = 0;
    byte[] bytes = line.toBytes();
    while idx < bytes.length() {
        byte b = bytes[idx];
        if b == 32 || b == 9 {
            idx += 1;
            continue;
        }
        break;
    }
    return idx > 0 ? line.substring(0, idx) : "";
}

function generateTestsWithAI(ConnectorAnalysis analysis) returns string|error {
    string prompt = createTestGenerationPrompt(analysis);

    string result = check callAI(prompt);

    return result;
}

function fixTestFileErrors(string connectorPath, boolean quietMode = false) returns error? {
    if !quietMode {
        io:println("Fixing compilation errors...");
    }

    string ballerinaDir = connectorPath + "/ballerina";

    // Use the fixer to fix all compilation errors related to tests
    code_fixer:FixResult|code_fixer:BallerinaFixerError fixResult = code_fixer:fixAllErrors(ballerinaDir,
            quietMode = quietMode, autoYes = true);

    if fixResult is code_fixer:FixResult {
        if fixResult.success {
            if !quietMode {
                io:println("✓ All files compile successfully!");
                if fixResult.errorsFixed > 0 {
                    io:println(string `  Fixed ${fixResult.errorsFixed} compilation error${fixResult.errorsFixed == 1 ? "" : "s"}`);
                    if fixResult.appliedFixes.length() > 0 {
                        io:println("  Applied fixes:");
                        foreach string fix in fixResult.appliedFixes {
                            io:println(string `    • ${fix}`);
                        }
                    }
                }
            } else {
                // In quiet mode, still show if we fixed errors
                if fixResult.errorsFixed > 0 {
                    io:println(string `✓ Fixed ${fixResult.errorsFixed} compilation error${fixResult.errorsFixed == 1 ? "" : "s"}`);
                }
            }
        } else {
            if !quietMode {
                io:println("⚠  Project partially fixed:");
                io:println(string `  Fixed: ${fixResult.errorsFixed} error${fixResult.errorsFixed == 1 ? "" : "s"}`);
                io:println(string `  Remaining: ${fixResult.errorsRemaining} error${fixResult.errorsRemaining == 1 ? "" : "s"}`);
                if fixResult.appliedFixes.length() > 0 {
                    io:println("  Applied fixes:");
                    foreach string fix in fixResult.appliedFixes {
                        io:println(string `    • ${fix}`);
                    }
                }
                io:println("  Some errors may require manual intervention");
            } else {
                io:println(string `⚠  Fixed ${fixResult.errorsFixed}/${fixResult.errorsFixed + fixResult.errorsRemaining} errors (${fixResult.errorsRemaining} remaining)`);
            }
            return error(string `Compilation errors remain after auto-fix (${fixResult.errorsRemaining} remaining)`);
        }
    } else {
        if !quietMode {
            io:println(string `✗ Failed to fix project: ${fixResult.message()}`);
        } else {
            io:println("✗ Compilation fix failed");
        }
        return error("Failed to fix compilation errors in the project", fixResult);
    }

    error? testCompilationError = fixBalTestCompilationErrors(ballerinaDir, quietMode);
    if testCompilationError is error {
        return testCompilationError;
    }

    return;
}

function fixBalTestCompilationErrors(string ballerinaDir, boolean quietMode = false) returns error? {
    int maxIterations = 2;
    int iteration = 1;

    while iteration <= maxIterations {
        CommandResult testResult = executeCommand("bal test", ballerinaDir, true);
        if testResult.success {
            return;
        }

        string diagnostics = string `${testResult.stderr}\n${testResult.stdout}`;
        code_fixer:CompilationError[] parseableErrors = code_fixer:parseCompilationErrors(diagnostics);
        code_fixer:CompilationError[] testErrors = [];
        foreach code_fixer:CompilationError err in parseableErrors {
            string lowerPath = err.filePath.toLowerAscii();
            if lowerPath.endsWith(".bal") && !lowerPath.includes("_backup") && !lowerPath.endsWith(".bak") {
                testErrors.push(err);
            }
        }

        if testErrors.length() == 0 {
            return error("`bal test` failed but no parseable Ballerina compilation errors were found");
        }

        map<code_fixer:CompilationError[]> errorsByFile = code_fixer:groupErrorsByFile(testErrors);
        boolean anyFixApplied = false;

        if !quietMode {
            io:println(string `  Attempting test error fixes: ${testErrors.length()} errors (iteration ${iteration}/${maxIterations})`);
        }

        foreach string filePath in errorsByFile.keys() {
            code_fixer:CompilationError[] fileErrors = errorsByFile.get(filePath);
            code_fixer:FixResponse|error fileFix = code_fixer:fixFileWithLLM(ballerinaDir, filePath, fileErrors,
                quietMode);
            if fileFix is error {
                continue;
            }

            boolean|error applyResult = code_fixer:applyFix(ballerinaDir, filePath, fileFix.fixedCode, quietMode);
            if applyResult is boolean && applyResult {
                anyFixApplied = true;
            }
        }

        if !anyFixApplied {
            return error("Unable to apply fixes for `bal test` compilation errors");
        }

        iteration += 1;
    }

    CommandResult finalResult = executeCommand("bal test", ballerinaDir, true);
    if finalResult.success {
        return;
    }

    code_fixer:CompilationError[] remaining = code_fixer:parseCompilationErrors(
        string `${finalResult.stderr}\n${finalResult.stdout}`);
    return error(string `Compilation errors remain after test-fix phase (${remaining.length()} remaining)`);
}

function sanitizeGeneratedCode(string content) returns string {
    string trimmed = content.trim();
    if !trimmed.startsWith("```") {
        return trimmed;
    }

    string[] lines = regexp:split(re `\n`, trimmed);
    if lines.length() <= 2 {
        return trimmed;
    }

    int startIndex = 0;
    if lines[0].trim().startsWith("```") {
        startIndex = 1;
    }

    int endExclusive = lines.length();
    if lines[lines.length() - 1].trim() == "```" {
        endExclusive = lines.length() - 1;
    }

    if startIndex >= endExclusive {
        return trimmed;
    }

    return string:'join("\n", ...lines.slice(startIndex, endExclusive)).trim();
}

// ---------------------------------------------------------------------------
// Spec analysis helpers (moved from removed mock_service_generator.bal)
// ---------------------------------------------------------------------------

function countOperationsInSpec(string specPath) returns int|error {
    string specContent = check io:fileReadString(specPath);
    if specPath.toLowerAscii().endsWith(".bal") || specContent.includes("public isolated client class Client {") {
        return extractRemoteOperationIdsFromSpec(specContent).length();
    }
    regexp:RegExp operationIdPattern = re `"operationId"\s*:\s*"[^"]*"`;
    regexp:Span[] matches = operationIdPattern.findAll(specContent);
    return matches.length();
}

function extractRemoteOperationIdsFromSpec(string specContent) returns string[] {
    string[] operationIds = [];
    string[] lines = regexp:split(re `\n`, specContent);
    foreach string line in lines {
        string trimmed = line.trim();
        if !trimmed.startsWith("remote isolated function ") {
            continue;
        }
        int startIdx = 25;
        int? paren = trimmed.indexOf("(");
        if paren is int && <int>paren > startIdx {
            string operationId = trimmed.substring(startIdx, <int>paren).trim();
            if operationId.length() > 0 {
                operationIds.push(operationId);
            }
        }
    }
    return operationIds;
}

function selectOperationsUsingAI(string specPath, boolean quietMode = false) returns string|error {
    string[] allOperationIds = check extractOperationIdsFromSpec(specPath);

    if !quietMode {
        io:println(string `  Found ${allOperationIds.length()} operations, selecting ${MAX_OPERATIONS} for testing`);
    }

    string prompt = createOperationSelectionPrompt(allOperationIds, MAX_OPERATIONS);

    string aiResponse = check callAI(prompt);

    // Clean up the AI response - simple string operations
    string cleanedResponse = strings:trim(aiResponse);
    // Remove code blocks if present
    if strings:includes(cleanedResponse, "```") {
        int? startIndexOpt = cleanedResponse.indexOf("```");
        if startIndexOpt is int {
            int startIndex = startIndexOpt;
            int? endIndexOpt = cleanedResponse.indexOf("```", startIndex + 3);
            if endIndexOpt is int && endIndexOpt > startIndex {
                cleanedResponse = cleanedResponse.substring(startIndex + 3, endIndexOpt);
                cleanedResponse = strings:trim(cleanedResponse);
            }
        }
    }

    // Validate that we got a proper comma-separated list
    if !strings:includes(cleanedResponse, ",") {
        return error("AI did not return a proper comma-separated list of operations");
    }

    if !quietMode {
        io:println("✓ Operations selected using AI");
    }

    return cleanedResponse;
}

function extractOperationIdsFromSpec(string specPath) returns string[]|error {
    string specContent = check io:fileReadString(specPath);

    if specPath.toLowerAscii().endsWith(".bal") || specContent.includes("public isolated client class Client {") {
        return extractRemoteOperationIds(specContent);
    }

    string[] operationIds = [];
    string searchPattern = "\"operationId\"";
    int currentPos = 0;

    while true {
        int? foundPos = specContent.indexOf(searchPattern, currentPos);
        if foundPos is () {
            break;
        }

        int searchPos = foundPos + searchPattern.length();
        int? colonPos = specContent.indexOf(":", searchPos);
        if colonPos is () {
            currentPos = foundPos + 1;
            continue;
        }

        int? firstQuotePos = specContent.indexOf("\"", colonPos + 1);
        if firstQuotePos is () {
            currentPos = foundPos + 1;
            continue;
        }

        int? secondQuotePos = specContent.indexOf("\"", firstQuotePos + 1);
        if secondQuotePos is () {
            currentPos = foundPos + 1;
            continue;
        }

        string operationId = specContent.substring(firstQuotePos + 1, secondQuotePos);
        if operationId.length() > 0 {
            operationIds.push(operationId);
        }

        currentPos = secondQuotePos + 1;
    }

    return operationIds;
}

function extractRemoteOperationIds(string specContent) returns string[] {
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
            string name = trimmed.substring(startIndex, <int>paren).trim();
            if name.length() > 0 {
                operationIds.push(name);
            }
        }
    }
    return operationIds;
}
