import ballerina/file;
import ballerina/io;
import ballerina/os;
import ballerina/regex;

import wso2/connector_automation.api_specification_generator as generator;
import wso2/connector_automation.code_fixer as fixer;
import wso2/connector_automation.connector_generator as connector;
import wso2/connector_automation.document_generator as document_generator;
import wso2/connector_automation.example_generator as example_generator;
import wso2/connector_automation.sdkanalyzer as analyzer;
import wso2/connector_automation.test_generator as test_generator;

const string TEST_JARS_DIR = "test-jars";
const string ANALYZER_OUTPUT_DIR = "modules/sdkanalyzer/output";
const string IR_OUTPUT_DIR = "modules/api_specification_generator/IR-output";
const string SPEC_OUTPUT_DIR = "modules/api_specification_generator/spec-output";
const string CONNECTOR_OUTPUT_DIR = "modules/connector_generator/output";

public function main(string... args) returns error? {
    if args.length() == 0 {
        printMainUsage();
        return;
    }

    string command = args[0];

    match command {
        "analyze" => {
            return executeAnalyze(args.slice(1));
        }
        "generate" => {
            return executeGenerate(args.slice(1));
        }
        "connector" => {
            return executeConnector(args.slice(1));
        }
        "fix-code" => {
            return executeFixCode(args.slice(1));
        }
        "fix-report-only" => {
            return executeFixReportOnly(args.slice(1));
        }
        "pipeline" => {
            return executePipeline(args.slice(1));
        }
        "generate-tests" => {
            return executeGenerateTests(args.slice(1));
        }
        "generate-examples" => {
            return executeGenerateExamples(args.slice(1));
        }
        "generate-docs" => {
            return executeGenerateDocs(args.slice(1));
        }
        _ => {
            printMainUsage();
            return error(string `Unknown command: ${command}`);
        }
    }
}

function executeAnalyze(string[] args) returns error? {
    if args.length() < 1 {
        printAnalyzeUsage();
        return;
    }

    string sdkRef = args[0].trim();
    if sdkRef.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string[] flagArgs = args.slice(1);

    AnalyzerFlags flags = parseAnalyzerFlags(flagArgs);

    if isMavenCoordinate(sdkRef) {
        analyzer:AnalyzerConfig analyzerConfig = buildAnalyzerConfig(args.slice(1), "", flags.quietMode);

        analyzer:AnalysisResult|analyzer:AnalyzerError analysisResult = analyzer:analyzeJavaSDK(
                sdkRef,
                ANALYZER_OUTPUT_DIR,
                analyzerConfig
        );

        if analysisResult is analyzer:AnalyzerError {
            io:println(string `Analysis failed: ${analysisResult.message()}`);
            return analysisResult;
        }

        return;
    }

    string datasetKey = sdkRef;
    string sdkJarPath = resolveSdkJarPath(datasetKey);
    string javadocJarPath = resolveJavadocJarPath(datasetKey);

    check ensureFileExists(sdkJarPath, "SDK JAR");
    check ensureFileExists(javadocJarPath, "Javadoc JAR");

    analyzer:AnalyzerConfig analyzerConfig = buildAnalyzerConfig(args.slice(1), javadocJarPath, flags.quietMode);

    analyzer:AnalysisResult|analyzer:AnalyzerError analysisResult = analyzer:analyzeJavaSDK(
            sdkJarPath,
            ANALYZER_OUTPUT_DIR,
            analyzerConfig
    );

    if analysisResult is analyzer:AnalyzerError {
        io:println(string `Analysis failed: ${analysisResult.message()}`);
        return analysisResult;
    }

}

function isMavenCoordinate(string sdkRef) returns boolean {
    if !sdkRef.includes(":") {
        return false;
    }

    if sdkRef.includes("/") || sdkRef.includes("\\") {
        return false;
    }

    string[] parts = regex:split(sdkRef, ":");
    return parts.length() == 2 || parts.length() == 3;
}

function executeGenerate(string[] args) returns error? {
    if args.length() < 1 {
        printGenerateUsage();
        return;
    }

    string datasetKey = args[0].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string metadataPath = resolveMetadataPath(datasetKey);
    check ensureFileExists(metadataPath, "Metadata JSON");

    generator:GeneratorConfig config = {
        metadataPath: metadataPath,
        outputDir: SPEC_OUTPUT_DIR,
        datasetKey: datasetKey
    };

    foreach string arg in args.slice(1) {
        match arg {
            "quiet"|"--quiet"|"-q" => {
                config.quietMode = true;
            }
            "no-thinking"|"--no-thinking" => {
                config.enableExtendedThinking = false;
            }
            _ => {
            }
        }
    }

    generator:GeneratorResult|generator:GeneratorError result = generator:generateSpecification(config);
    if result is generator:GeneratorError {
        io:println(string `Generation failed: ${result.message()}`);
        return result;
    }

}

function executeConnector(string[] args) returns error? {
    if args.length() < 1 {
        printConnectorUsage();
        return;
    }

    string datasetKey = args[0].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string metadataPath = resolveMetadataPath(datasetKey);
    string irPath = resolveIrPath(datasetKey);
    string specPath = resolveSpecPath(datasetKey);

    check ensureFileExists(metadataPath, "Metadata JSON");
    check ensureFileExists(irPath, "IR JSON");
    check ensureFileExists(specPath, "API specification");

    connector:ConnectorGeneratorConfig config = {
        metadataPath: metadataPath,
        irPath: irPath,
        apiSpecPath: specPath,
        outputDir: resolveConnectorOutputPath(datasetKey),
        sdkVersionHint: extractSdkVersionFromDatasetKey(datasetKey)
    };

    foreach string arg in args.slice(1) {
        if arg == "quiet" || arg == "--quiet" || arg == "-q" {
            config.quietMode = true;
        }
    }

    connector:ConnectorGeneratorResult|connector:ConnectorGeneratorError result = connector:generateConnector(config);
    if result is connector:ConnectorGeneratorError {
        io:println(string `Connector generation failed: ${result.message()}`);
        return result;
    }

}

function executeFixCode(string[] args) returns error? {
    return executeFixCommand(args, "auto-apply");
}

function executeGenerateTests(string[] args) returns error? {
    if args.length() < 1 {
        printGenerateTestsUsage();
        return;
    }

    string datasetKey = args[0].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string specPath = toAbsolutePath(resolveSpecPath(datasetKey));
    check ensureFileExists(specPath, "API specification");

    string connectorOutputPath = resolveConnectorOutputPath(datasetKey);
    string connectorBallerinaToml = string `${connectorOutputPath}/ballerina/Ballerina.toml`;
    check ensureFileExists(connectorBallerinaToml, "Generated connector output");

    string[] forwardedArgs = [connectorOutputPath, specPath, ...args.slice(1)];
    return test_generator:executeTestGen(...forwardedArgs);
}

function executeGenerateExamples(string[] args) returns error? {
    if args.length() < 1 {
        printGenerateExamplesUsage();
        return;
    }

    string datasetKey = args[0].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string connectorOutputPath = resolveConnectorOutputPath(datasetKey);
    string connectorBallerinaToml = string `${connectorOutputPath}/ballerina/Ballerina.toml`;
    check ensureFileExists(connectorBallerinaToml, "Generated connector output");

    string[] forwardedArgs = [connectorOutputPath, ...args.slice(1)];
    return example_generator:executeExampleGen(...forwardedArgs);
}

function executeGenerateDocs(string[] args) returns error? {
    if args.length() < 2 {
        printGenerateDocsUsage();
        return;
    }

    string docCommand = args[0].trim();
    string datasetKey = args[1].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string connectorOutputPath = resolveConnectorOutputPath(datasetKey);
    string connectorBallerinaToml = string `${connectorOutputPath}/ballerina/Ballerina.toml`;
    check ensureFileExists(connectorBallerinaToml, "Generated connector output");

    string[] forwardedArgs = [docCommand, connectorOutputPath, ...args.slice(2)];
    return document_generator:executeDocGen(...forwardedArgs);
}

function printGenerateTestsUsage() {
    io:println();
    io:println("Generate connector tests from dataset key");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- generate-tests <dataset-key> [yes] [quiet]");
    io:println();
    io:println("INPUTS:");
    io:println("  modules/api_specification_generator/spec-output/<dataset-key>_spec.bal");
    io:println("  modules/connector_generator/output/<dataset-key>/ballerina/... (generated connector)");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- generate-tests sqs-2.31.66 yes quiet");
    io:println();
}

function printGenerateExamplesUsage() {
    io:println();
    io:println("Generate connector examples from dataset key");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- generate-examples <dataset-key> [yes] [quiet]");
    io:println();
    io:println("INPUTS:");
    io:println("  modules/connector_generator/output/<dataset-key>/ballerina/... (generated connector)");
    io:println();
    io:println("OUTPUT:");
    io:println("  modules/connector_generator/output/<dataset-key>/examples/");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- generate-examples sqs-2.31.66 yes quiet");
    io:println();
}

function printGenerateDocsUsage() {
    io:println();
    io:println("Generate connector documentation from dataset key");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- generate-docs <doc-command> <dataset-key> [yes] [quiet]");
    io:println();
    io:println("DOC COMMANDS:");
    io:println("  generate-all");
    io:println("  generate-ballerina");
    io:println("  generate-tests");
    io:println("  generate-examples");
    io:println("  generate-individual-examples");
    io:println("  generate-main");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- generate-docs generate-all sqs-2.31.66 yes quiet");
    io:println();
}

function executeFixReportOnly(string[] args) returns error? {
    return executeFixCommand(args, "report-only");
}

function executeFixCommand(string[] args, string fixMode) returns error? {
    if args.length() < 1 {
        printFixUsage(fixMode);
        return;
    }

    string datasetKey = args[0].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string metadataPath = resolveMetadataPath(datasetKey);
    string irPath = resolveIrPath(datasetKey);
    string specPath = resolveSpecPath(datasetKey);

    check ensureFileExists(metadataPath, "Metadata JSON");
    check ensureFileExists(irPath, "IR JSON");
    check ensureFileExists(specPath, "API specification");

    boolean quietMode = false;
    int maxFixIterations = 3;
    boolean autoYes = fixMode != "report-only";
    string connectorOutputPath = resolveConnectorOutputPath(datasetKey);
    string ballerinaOutputPath = string `${connectorOutputPath}/ballerina`;

    check ensureFileExists(string `${connectorOutputPath}/build.gradle`, "Generated connector build.gradle");

    foreach string arg in args.slice(1) {
        if arg == "quiet" || arg == "--quiet" || arg == "-q" {
            quietMode = true;
        } else if arg.startsWith("--fix-iterations=") {
            string val = arg.substring(17);
            int|error parsed = int:fromString(val);
            if parsed is int {
                maxFixIterations = parsed;
            }
        }
    }

    string[] planOperations = fixMode == "report-only"
        ? [
            "Run Java native fixer",
            "Collect Java/native fix status",
            "Report consolidated fix status"
        ]
        : [
            "Run Java native fixer",
            "Run Ballerina client/types fixer",
            "Report consolidated fix status"
        ];

    printCommandPlan(fixMode == "report-only" ? "Fix Report" : "Fix Code", datasetKey,
        planOperations, quietMode);

    fixer:FixResult|fixer:BallerinaFixerError javaFixResultOrError = fixer:fixJavaNativeAdaptorErrors(
            connectorOutputPath,
            quietMode,
            autoYes,
            maxFixIterations
    );

    if javaFixResultOrError is fixer:BallerinaFixerError {
        io:println(string `Code fix failed (Java native): ${javaFixResultOrError.message()}`);
        return javaFixResultOrError;
    }

    fixer:FixResult javaFixResult = javaFixResultOrError;

    fixer:FixResult ballerinaFixResult = {
        success: true,
        errorsFixed: 0,
        errorsRemaining: 0,
        appliedFixes: [],
        remainingFixes: []
    };

    if fixMode != "report-only" {
        check ensureFileExists(string `${ballerinaOutputPath}/Ballerina.toml`, "Generated connector Ballerina.toml");
        fixer:FixResult|fixer:BallerinaFixerError ballerinaFixResultOrError = fixer:fixAllErrors(
                ballerinaOutputPath,
                quietMode,
                autoYes
        );

        if ballerinaFixResultOrError is fixer:BallerinaFixerError {
            io:println(string `Code fix failed (Ballerina client): ${ballerinaFixResultOrError.message()}`);
            return ballerinaFixResultOrError;
        }
        ballerinaFixResult = ballerinaFixResultOrError;
    }

    boolean overallSuccess = javaFixResult.success && ballerinaFixResult.success;
    int totalFixed = javaFixResult.errorsFixed + ballerinaFixResult.errorsFixed;
    int totalRemaining = javaFixResult.errorsRemaining + ballerinaFixResult.errorsRemaining;

    string[] combinedIssues = [];
    foreach string issue in javaFixResult.remainingFixes {
        combinedIssues.push(string `java: ${issue}`);
    }
    foreach string issue in ballerinaFixResult.remainingFixes {
        combinedIssues.push(string `ballerina: ${issue}`);
    }

    string[] details = [
        string `success: ${overallSuccess}`,
        string `fixed: ${totalFixed}`,
        string `remaining: ${totalRemaining}`,
        string `java_remaining: ${javaFixResult.errorsRemaining}`
    ];
    if fixMode != "report-only" {
        details.push(string `ballerina_remaining: ${ballerinaFixResult.errorsRemaining}`);
    }
    if !overallSuccess && combinedIssues.length() > 0 {
        foreach string issue in combinedIssues {
            details.push(string `issue: ${issue}`);
        }
    }
    printCommandSummary(fixMode == "report-only" ? "Fix Report" : "Fix Code", overallSuccess, details, quietMode);
}

function printCommandPlan(string title, string target, string[] operations, boolean quietMode) {
    if quietMode {
        return;
    }

    string sep = createMainSeparator("=", 70);
    io:println(sep);
    io:println(string `${title} Plan`);
    io:println(sep);
    io:println(string `Target: ${target}`);
    io:println("");
    io:println("Operations:");
    int i = 0;
    while i < operations.length() {
        io:println(string `  ${i + 1}. ${operations[i]}`);
        i += 1;
    }
    io:println(sep);
}

function printCommandSummary(string title, boolean success, string[] details, boolean quietMode) {
    string sep = createMainSeparator("=", 70);
    io:println("");
    io:println(sep);
    io:println(string `${success ? "✓" : "⚠"} ${title} Complete`);
    io:println(sep);
    foreach string detail in details {
        io:println(string `  • ${detail}`);
    }
    if !quietMode {
        io:println(sep);
    }
}

function createMainSeparator(string char, int length) returns string {
    string[] chars = [];
    int i = 0;
    while i < length {
        chars.push(char);
        i += 1;
    }
    return string:'join("", ...chars);
}

function printConnectorUsage() {
    io:println();
    io:println("Generate connector artifacts from fixed metadata/IR/spec locations");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- connector <dataset-key> [options]");
    io:println();
    io:println("INPUTS:");
    io:println("  modules/sdkanalyzer/output/<dataset-key>-metadata.json");
    io:println("  modules/api_specification_generator/IR-output/<dataset-key>-ir.json");
    io:println("  modules/api_specification_generator/spec-output/<dataset-key>_spec.bal");
    io:println();
    io:println("OUTPUT:");
    io:println("  modules/connector_generator/output/<dataset-key>/ballerina/client.bal");
    io:println("  modules/connector_generator/output/<dataset-key>/ballerina/types.bal");
    io:println("  modules/connector_generator/output/<dataset-key>/src/main/java/... (native adaptor)");
    io:println();
    io:println("OPTIONS:");
    io:println("  quiet                   Minimal logging output");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- connector s3-2.4.0");
    io:println();
}

function printFixUsage(string fixMode) {
    io:println();
    io:println("Run code fixer on generated connector output (Java native + Ballerina client)");
    io:println();
    io:println("USAGE:");
    if fixMode == "report-only" {
        io:println("  bal run -- fix-report-only <dataset-key> [options]");
    } else {
        io:println("  bal run -- fix-code <dataset-key> [options]");
    }
    io:println();
    io:println("INPUTS:");
    io:println("  modules/sdkanalyzer/output/<dataset-key>-metadata.json");
    io:println("  modules/api_specification_generator/IR-output/<dataset-key>-ir.json");
    io:println("  modules/api_specification_generator/spec-output/<dataset-key>_spec.bal");
    io:println();
    io:println("OUTPUT:");
    io:println("  modules/connector_generator/output/<dataset-key>/ballerina/client.bal");
    io:println("  modules/connector_generator/output/<dataset-key>/ballerina/types.bal");
    io:println("  modules/connector_generator/output/<dataset-key>/src/main/java/... (native adaptor)");
    io:println();
    io:println("OPTIONS:");
    io:println("  --fix-iterations=<n>    Maximum fixer iterations (default: 3)");
    io:println("  quiet                   Minimal logging output");
    io:println();
    io:println("EXAMPLES:");
    io:println("  bal run -- fix-code s3-2.4.0");
    io:println("  bal run -- fix-report-only s3-2.4.0");
    io:println();
}

function executePipeline(string[] args) returns error? {
    if args.length() < 1 {
        printPipelineUsage();
        return;
    }

    string datasetKey = args[0].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string sdkJarPath = resolveSdkJarPath(datasetKey);
    string javadocJarPath = resolveJavadocJarPath(datasetKey);

    check ensureFileExists(sdkJarPath, "SDK JAR");
    check ensureFileExists(javadocJarPath, "Javadoc JAR");

    boolean quietMode = false;
    boolean autoYes = false;
    boolean runFixCode = true;
    boolean runGenerateTests = true;
    boolean runGenerateExamples = true;
    boolean runGenerateDocs = true;
    string fixMode = "auto-apply";
    int maxFixIterations = 3;
    foreach string arg in args.slice(1) {
        if arg == "quiet" || arg == "--quiet" || arg == "-q" {
            quietMode = true;
        } else if arg == "yes" || arg == "--yes" || arg == "-y" {
            autoYes = true;
        } else if arg == "--fix-code" {
            runFixCode = true;
        } else if arg == "--fix-report-only" {
            runFixCode = true;
            fixMode = "report-only";
        } else if arg == "--skip-fix" {
            runFixCode = false;
        } else if arg == "--skip-tests" {
            runGenerateTests = false;
        } else if arg == "--generate-examples" {
            runGenerateExamples = true;
        } else if arg == "--skip-examples" {
            runGenerateExamples = false;
        } else if arg == "--generate-docs" {
            runGenerateDocs = true;
        } else if arg == "--skip-docs" {
            runGenerateDocs = false;
        } else if arg.startsWith("--fix-iterations=") {
            string value = arg.substring(17);
            int|error parsed = int:fromString(value);
            if parsed is int {
                maxFixIterations = parsed;
            }
        }
    }

    printPipelineModuleHeader("SDK Analyzer", quietMode);
    if !quietMode {
        io:println(string `  → SDK JAR: ${sdkJarPath}`);
        io:println(string `  → Javadoc JAR: ${javadocJarPath}`);
    }

    analyzer:AnalyzerConfig analyzerConfig = buildAnalyzerConfig(args.slice(1), javadocJarPath, quietMode);
    analyzer:AnalysisResult|analyzer:AnalyzerError analysisResult = analyzer:analyzeJavaSDK(
            sdkJarPath,
            ANALYZER_OUTPUT_DIR,
            analyzerConfig
    );
    if analysisResult is analyzer:AnalyzerError {
        io:println(string `Analysis failed: ${analysisResult.message()}`);
        return analysisResult;
    }

    string metadataPath = resolveMetadataPath(datasetKey);
    check ensureFileExists(metadataPath, "Metadata JSON");

    check runPipelineStagesForDataset(datasetKey, analysisResult.methodsExtracted, autoYes, quietMode,
        runFixCode, runGenerateTests, runGenerateExamples, runGenerateDocs, fixMode, maxFixIterations);
}

function runPipelineStagesForDataset(string datasetKey, int extractedMethods, boolean autoYes, boolean quietMode,
        boolean runFixCode, boolean runGenerateTests, boolean runGenerateExamples, boolean runGenerateDocs,
        string fixMode, int maxFixIterations) returns error? {
    string metadataPath = resolveMetadataPath(datasetKey);
    check ensureFileExists(metadataPath, "Metadata JSON");

    printPipelineModuleHeader("API Specification Generator", quietMode);
    if !quietMode {
        io:println(string `  → Metadata: ${metadataPath}`);
    }

    generator:GeneratorConfig genConfig = {
        metadataPath: metadataPath,
        outputDir: SPEC_OUTPUT_DIR,
        quietMode: quietMode,
        datasetKey: datasetKey
    };

    generator:GeneratorResult|generator:GeneratorError genResult = generator:generateSpecification(genConfig);
    if genResult is generator:GeneratorError {
        io:println(string `Specification generation failed: ${genResult.message()}`);
        return genResult;
    }

    string irPath = resolveIrPath(datasetKey);
    string specPath = resolveSpecPath(datasetKey);
    check ensureFileExists(irPath, "IR JSON");
    check ensureFileExists(specPath, "API specification");

    if !confirmPipelineAfterSpec(datasetKey, metadataPath, irPath, specPath, autoYes, quietMode) {
        return error("Pipeline cancelled by user after API specification generation.");
    }

    printPipelineModuleHeader("Connector Generator", quietMode);
    if !quietMode {
        io:println(string `  → IR: ${irPath}`);
        io:println(string `  → API Spec: ${specPath}`);
    }

    connector:ConnectorGeneratorConfig connectorConfig = {
        metadataPath: metadataPath,
        irPath: irPath,
        apiSpecPath: specPath,
        outputDir: resolveConnectorOutputPath(datasetKey),
        quietMode: quietMode,
        enableCodeFixing: false,
        fixMode: fixMode,
        maxFixIterations: maxFixIterations,
        sdkVersionHint: extractSdkVersionFromDatasetKey(datasetKey)
    };

    connector:ConnectorGeneratorResult|connector:ConnectorGeneratorError connectorResult =
        connector:generateConnector(connectorConfig);

    if connectorResult is connector:ConnectorGeneratorError {
        io:println(string `Connector generation failed: ${connectorResult.message()}`);
        return connectorResult;
    }

    boolean fixCompleted = false;
    if runFixCode {
        printPipelineModuleHeader("Code Fixer", quietMode);

        string[] fixArgs = [datasetKey];
        if quietMode {
            fixArgs.push("quiet");
        }
        if autoYes {
            fixArgs.push("yes");
        }
        error? fixError = executeFixCommand(fixArgs, fixMode);
        if fixError is error {
            return fixError;
        }
        fixCompleted = true;
    }

    boolean testsCompleted = false;
    if runGenerateTests {
        printPipelineModuleHeader("Test Generator", quietMode);

        string[] testArgs = [datasetKey, "yes"];
        if quietMode {
            testArgs.push("quiet");
        }
        error? testError = executeGenerateTests(testArgs);
        if testError is error {
            return testError;
        }
        testsCompleted = true;
    }

    boolean examplesCompleted = false;
    if runGenerateExamples {
        printPipelineModuleHeader("Example Generator", quietMode);

        string[] exampleArgs = [datasetKey];
        if autoYes {
            exampleArgs.push("yes");
        }
        if quietMode {
            exampleArgs.push("quiet");
        }

        error? exampleError = executeGenerateExamples(exampleArgs);
        if exampleError is error {
            return exampleError;
        }
        examplesCompleted = true;
    }

    boolean docsCompleted = false;
    if runGenerateDocs {
        printPipelineModuleHeader("Document Generator", quietMode);

        string[] docArgs = ["generate-all", datasetKey];
        if autoYes {
            docArgs.push("yes");
        }
        if quietMode {
            docArgs.push("quiet");
        }

        error? docsError = executeGenerateDocs(docArgs);
        if docsError is error {
            return docsError;
        }
        docsCompleted = true;
    }

    printPipelineFinalSummary(datasetKey, metadataPath, irPath, genResult.specificationPath,
        connectorResult.clientPath, connectorResult.typesPath, connectorResult.nativeAdaptorPath,
        extractedMethods, connectorResult.mappedMethodCount,
        runFixCode, fixCompleted, runGenerateTests, testsCompleted, runGenerateExamples, examplesCompleted,
        runGenerateDocs, docsCompleted,
        connectorResult.codeFixingRan, connectorResult.codeFixingSuccess, quietMode);
}

function printPipelineModuleHeader(string moduleName, boolean quietMode) {
    if quietMode {
        return;
    }

    string sep = createMainSeparator("-", 60);
    io:println("");
    io:println(sep);
    io:println(string `Executing module: ${moduleName}`);
    io:println(sep);
}

function confirmPipelineAfterSpec(string datasetKey, string metadataPath, string irPath, string specPath,
        boolean autoYes, boolean quietMode) returns boolean {
    if quietMode || autoYes {
        return true;
    }

    string sep = createMainSeparator("-", 60);
    io:println("");
    io:println(sep);
    io:println("Generated artifacts after API specification generation");
    io:println(sep);
    io:println(string `Dataset: ${datasetKey}`);
    io:println(string `Metadata: ${metadataPath}`);
    io:println(string `IR: ${irPath}`);
    io:println(string `Specification: ${specPath}`);
    io:println(sep);

    return getPipelineUserConfirmation("Continue pipeline with these generated artifacts?");
}

function getPipelineUserConfirmation(string message) returns boolean {
    io:print(string `${message} (y/n): `);
    string|io:Error userInput = io:readln();
    if userInput is io:Error {
        return false;
    }
    return userInput.trim().toLowerAscii() is "y"|"yes";
}

function printPipelineFinalSummary(string datasetKey, string metadataPath, string irPath, string specPath,
        string clientPath, string typesPath, string nativePath, int extractedMethods, int mappedMethods,
    boolean runFixCode, boolean fixCompleted, boolean runGenerateTests, boolean testsCompleted,
    boolean runGenerateExamples, boolean examplesCompleted,
    boolean runGenerateDocs, boolean docsCompleted,
        boolean connectorInternalFixRan, boolean connectorInternalFixSuccess, boolean quietMode) {
    string sep = createMainSeparator("=", 70);
    io:println("");
    io:println(sep);
    io:println("Pipeline Summary");
    io:println(sep);
    io:println(string `Dataset: ${datasetKey}`);
    io:println(string `Metadata: ${metadataPath}`);
    io:println(string `IR: ${irPath}`);
    io:println(string `Specification: ${specPath}`);
    io:println(string `Connector client: ${clientPath}`);
    io:println(string `Connector types: ${typesPath}`);
    io:println(string `Native adaptor: ${nativePath}`);
    io:println(string `Methods extracted: ${extractedMethods}`);
    io:println(string `Methods mapped: ${mappedMethods}`);
    io:println(string `Code fixing: ${runFixCode ? (fixCompleted ? "completed" : "failed") : "skipped"}`);
    io:println(string `Test generation: ${runGenerateTests ? (testsCompleted ? "completed" : "failed") : "skipped"}`);
    io:println(string `Example generation: ${runGenerateExamples ? (examplesCompleted ? "completed" : "failed") : "skipped"}`);
    io:println(string `Documentation generation: ${runGenerateDocs ? (docsCompleted ? "completed" : "failed") : "skipped"}`);
    if connectorInternalFixRan {
        io:println(string `Connector-internal code fixing: ${connectorInternalFixSuccess ? "success" : "partial/failed"}`);
    }
    if !quietMode {
        io:println(sep);
    }
}

type AnalyzerFlags record {|
    boolean quietMode;
|};

function parseAnalyzerFlags(string[] args) returns AnalyzerFlags {
    AnalyzerFlags flags = {
        quietMode: false
    };

    foreach string arg in args {
        if arg == "quiet" || arg == "--quiet" || arg == "-q" {
            flags.quietMode = true;
        }
    }

    return flags;
}

function buildAnalyzerConfig(string[] args, string javadocJar, boolean quietMode) returns analyzer:AnalyzerConfig {
    analyzer:AnalyzerConfig config = {
        quietMode: quietMode
    };

    if javadocJar.trim().length() > 0 {
        config.javadocPath = javadocJar;
    }

    int i = 0;
    while i < args.length() {
        string arg = args[i];
        match arg {
            "yes"|"--yes"|"-y" => {
                config.autoYes = true;
            }
            "quiet"|"--quiet"|"-q" => {
                config.quietMode = true;
            }
            "include-deprecated"|"--include-deprecated" => {
                config.includeDeprecated = true;
            }
            "include-internal"|"--include-internal" => {
                config.filterInternal = false;
            }
            "include-non-public"|"--include-non-public" => {
                config.includeNonPublic = true;
            }
            "--sources" => {
                if i + 1 < args.length() {
                    config.sourcesPath = args[i + 1];
                    i = i + 1;
                }
            }
            _ => {
                if arg.includes("=") {
                    string[] parts = regex:split(arg, "=");
                    if parts.length() == 2 {
                        string key = parts[0].trim();
                        string value = parts[1].trim();

                        match key {
                            "exclude-packages"|"--exclude-packages" => {
                                if value.length() > 0 {
                                    config.excludePackages = regex:split(value, ",")
                                        .map(pkg => pkg.trim())
                                        .filter(pkg => pkg.length() > 0);
                                }
                            }
                            "include-packages"|"--include-packages" => {
                                if value.length() > 0 {
                                    config.includePackages = regex:split(value, ",")
                                        .map(pkg => pkg.trim())
                                        .filter(pkg => pkg.length() > 0);
                                }
                            }
                            "max-depth"|"--max-depth" => {
                                int|error depth = int:fromString(value);
                                if depth is int {
                                    config.maxDependencyDepth = depth;
                                }
                            }
                            "methods-to-list"|"--methods-to-list" => {
                                int|error methods = int:fromString(value);
                                if methods is int {
                                    config.methodsToList = methods;
                                }
                            }
                            "sources"|"--sources" => {
                                if value.length() > 0 {
                                    config.sourcesPath = value;
                                }
                            }
                            _ => {
                            }
                        }
                    }
                }
            }
        }
        i = i + 1;
    }

    return config;
}

function resolveSdkJarPath(string datasetKey) returns string {
    return string `${TEST_JARS_DIR}/${datasetKey}.jar`;
}

function resolveJavadocJarPath(string datasetKey) returns string {
    return string `${TEST_JARS_DIR}/${datasetKey}-javadoc.jar`;
}

function resolveMetadataPath(string datasetKey) returns string {
    return string `${ANALYZER_OUTPUT_DIR}/${datasetKey}-metadata.json`;
}

function resolveIrPath(string datasetKey) returns string {
    return string `${IR_OUTPUT_DIR}/${datasetKey}-ir.json`;
}

function resolveSpecPath(string datasetKey) returns string {
    return string `${SPEC_OUTPUT_DIR}/${datasetKey}_spec.bal`;
}

function extractSdkVersionFromDatasetKey(string datasetKey) returns string {
    string[] parts = regex:split(datasetKey, "-");
    foreach string part in parts.reverse() {
        if regex:matches(part, "^[0-9]+\\.[0-9]+.*") {
            return part;
        }
    }

    return "";
}

function resolveConnectorOutputPath(string datasetKey) returns string {
    if CONNECTOR_OUTPUT_DIR.startsWith("/") {
        return string `${CONNECTOR_OUTPUT_DIR}/${datasetKey}`;
    }
    string cwd = os:getEnv("PWD");
    return string `${cwd}/${CONNECTOR_OUTPUT_DIR}/${datasetKey}`;
}

function toAbsolutePath(string path) returns string {
    string trimmed = path.trim();
    if trimmed.startsWith("/") {
        return trimmed;
    }
    string cwd = os:getEnv("PWD");
    return string `${cwd}/${trimmed}`;
}

function ensureFileExists(string filePath, string fileLabel) returns error? {
    boolean exists = check file:test(filePath, file:EXISTS);
    if !exists {
        return error(string `${fileLabel} not found: ${filePath}`);
    }
}

# Print main usage information.
function printMainUsage() {
    io:println();
    io:println("Connector Automator – Simplified Dataset-Key Commands");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- <command> <dataset-key> [options]");
    io:println();
    io:println("COMMANDS:");
    io:println("  analyze    Analyze SDK and write metadata to modules/sdkanalyzer/output");
    io:println("  generate   Generate IR/spec from modules/sdkanalyzer/output/<key>-metadata.json");
    io:println("  connector  Generate connector from fixed metadata/IR/spec locations");
    io:println("  fix-code   Run code fixer on connector output (Java + Ballerina)");
    io:println("  fix-report-only  Run fixer diagnostics without applying fixes (Java native)");
    io:println("  pipeline   Run full pipeline end-to-end with fixed paths");
    io:println("  generate-tests Generate tests from generated Ballerina connector client");
    io:println("  generate-examples Generate examples from generated Ballerina connector client");
    io:println("  generate-docs Generate documentation from generated connector outputs");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- pipeline s3-2.4.0");
    io:println();
}

function printAnalyzeUsage() {
    io:println();
    io:println("Analyze Java SDK and write deterministic metadata output");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- analyze <dataset-key> [options]");
    io:println();
    io:println("INPUT RESOLUTION:");
    io:println("  SDK JAR      test-jars/<dataset-key>.jar");
    io:println("  Javadoc JAR  test-jars/<dataset-key>-javadoc.jar");
    io:println();
    io:println("OUTPUT:");
    io:println("  modules/sdkanalyzer/output/<dataset-key>-metadata.json");
    io:println();
    io:println("OPTIONS:");
    io:println("  quiet                       Minimal logging output");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- analyze s3-2.4.0 quiet");
    io:println("  bal run -- analyze kafka-clients-3.9.1");
    io:println();
}

# Print generate command usage.
function printGenerateUsage() {
    io:println();
    io:println("Generate Ballerina API specification from fixed metadata output");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- generate <dataset-key> [options]");
    io:println();
    io:println("INPUT:");
    io:println("  modules/sdkanalyzer/output/<dataset-key>-metadata.json");
    io:println();
    io:println("OUTPUT:");
    io:println("  modules/api_specification_generator/IR-output/<dataset-key>-ir.json");
    io:println("  modules/api_specification_generator/spec-output/<dataset-key>_spec.bal");
    io:println();
    io:println("OPTIONS:");
    io:println("  quiet            Minimal logging output");
    io:println("  no-thinking      Disable LLM extended thinking");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- generate s3-2.4.0");
    io:println();
}

# Print pipeline command usage.
function printPipelineUsage() {
    io:println();
    io:println("Full Pipeline: Analyze SDK → Generate API Spec → Generate Connector");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- pipeline <dataset-key> [options]");
    io:println();
    io:println("INPUT RESOLUTION:");
    io:println("  SDK JAR      test-jars/<dataset-key>.jar");
    io:println("  Javadoc JAR  test-jars/<dataset-key>-javadoc.jar");
    io:println();
    io:println("OUTPUTS:");
    io:println("  modules/sdkanalyzer/output/<dataset-key>-metadata.json");
    io:println("  modules/api_specification_generator/IR-output/<dataset-key>-ir.json");
    io:println("  modules/api_specification_generator/spec-output/<dataset-key>_spec.bal");
    io:println("  modules/connector_generator/output/<dataset-key>/... (ballerina + native java)");
    io:println();
    io:println("OPTIONS:");
    io:println("  yes                     Auto-confirm continuation prompts");
    io:println("  --fix-code              Run full code fixer phase (default: enabled)");
    io:println("  --fix-report-only       Run fixer in diagnostics mode");
    io:println("  --skip-fix              Skip code fixing phase");
    io:println("  --skip-tests            Skip test generation phase");
    io:println("  --generate-examples     Run example generation phase");
    io:println("  --skip-examples         Skip example generation phase");
    io:println("  --generate-docs         Run documentation generation phase");
    io:println("  --skip-docs             Skip documentation generation phase");
    io:println("  --fix-iterations=<n>    Maximum fixer iterations (default: 3)");
    io:println("  quiet                   Minimal logging output");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- pipeline s3-2.4.0 --fix-code");
    io:println();
}
