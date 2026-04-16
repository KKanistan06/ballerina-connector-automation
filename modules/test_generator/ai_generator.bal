import ballerina/io;
import ballerina/lang.'string as strings;
import ballerina/lang.regexp;

import wso2/connector_automation.code_fixer;

const int MAX_OPERATIONS = 40;

function completeMockServer(string mockServerPath, string typesPath, boolean quietMode = false) returns error? {
    // Read the generated mock server template
    string mockServerContent = check io:fileReadString(mockServerPath);
    string typesContent = check io:fileReadString(typesPath);

    int templateFunctionCount = countResourceFunctionDefinitions(mockServerContent);

    // generate completed mock server using LLM
    string prompt = createMockServerPrompt(mockServerContent, typesContent);

    string completedMockServer = check callAI(prompt);

    string candidateMockServer = sanitizeGeneratedCode(completedMockServer);
    boolean candidateValid = isMockServerComplete(candidateMockServer, templateFunctionCount);

    if !candidateValid {
        string retryPrompt = string `${prompt}

CRITICAL VALIDATION REQUIREMENTS:
- Preserve ALL existing resource functions from the template.
- Do NOT remove any function.
- Return a complete source file with balanced braces.
- Keep service and listener declarations unchanged.`;

        string retryResult = check callAI(retryPrompt);
        string retryCandidate = sanitizeGeneratedCode(retryResult);
        if isMockServerComplete(retryCandidate, templateFunctionCount) {
            candidateMockServer = retryCandidate;
            candidateValid = true;
        }
    }

    if !candidateValid {
        if !quietMode {
            io:println("⚠  AI mock completion returned incomplete output; preserving generated template");
        }
        candidateMockServer = mockServerContent;
    }

    check io:fileWriteString(mockServerPath, candidateMockServer);

    if !quietMode {
        io:println("✓ Mock server template completed successfully");
    }
    return;
}

function generateTestFile(string connectorPath, string[]? operationIds = (), boolean quietMode = false) returns error? {
    // Simplified analysis - only get package name and mock server content
    ConnectorAnalysis analysis = check analyzeConnectorForTests(connectorPath, operationIds);

    // Generate test content using AI
    string testContent = check generateTestsWithAI(analysis);

    // Write test file
    string testFilePath = connectorPath + "/ballerina/tests/test.bal";
    check io:fileWriteString(testFilePath, testContent);

    if !quietMode {
        io:println("✓ Test file generated successfully");
        io:println(string `  Output: ${testFilePath}`);
    }
    return;
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

function isMockServerComplete(string content, int expectedFunctionCount) returns boolean {
    if content.trim().length() == 0 {
        return false;
    }
    if !hasBalancedBraces(content) {
        return false;
    }
    int actualFunctionCount = countResourceFunctionDefinitions(content);
    return actualFunctionCount >= expectedFunctionCount;
}

function countResourceFunctionDefinitions(string content) returns int {
    string[] lines = regexp:split(re `\n`, content);
    int count = 0;
    foreach string line in lines {
        string trimmed = line.trim();
        if trimmed.startsWith("resource function ") {
            count += 1;
        }
    }
    return count;
}

function hasBalancedBraces(string content) returns boolean {
    int depth = 0;
    byte[] bytes = content.toBytes();
    foreach byte b in bytes {
        if b == 123 {
            depth += 1;
        } else if b == 125 {
            depth -= 1;
            if depth < 0 {
                return false;
            }
        }
    }
    return depth == 0;
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
