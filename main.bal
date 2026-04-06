import wso2/connector_automation.sdkanalyzer as analyzer;
import wso2/connector_automation.api_specification_generator as generator;
import wso2/connector_automation.connector_generator as connector;
import wso2/connector_automation.code_fixer as fixer;

import ballerina/file;
import ballerina/io;
import ballerina/os;
import ballerina/regex;

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

    string datasetKey = args[0].trim();
    if datasetKey.length() == 0 {
        return error("Dataset key cannot be empty");
    }

    string sdkJarPath = resolveSdkJarPath(datasetKey);
    string javadocJarPath = resolveJavadocJarPath(datasetKey);

    check ensureFileExists(sdkJarPath, "SDK JAR");
    check ensureFileExists(javadocJarPath, "Javadoc JAR");

    AnalyzerFlags flags = parseAnalyzerFlags(args.slice(1));
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

    io:println(string `Metadata generated: ${analysisResult.metadataPath}`);
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
            "quiet" | "--quiet" | "-q" => {
                config.quietMode = true;
            }
            "no-thinking" | "--no-thinking" => {
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

    io:println(string `Specification generated: ${result.specificationPath}`);
    if result.irPath is string {
        io:println(string `IR generated: ${<string>result.irPath}`);
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
        outputDir: CONNECTOR_OUTPUT_DIR,
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

    io:println("Connector generated:");
    io:println(string `  client: ${result.clientPath}`);
    io:println(string `  types:  ${result.typesPath}`);
    io:println(string `  native: ${result.nativeAdaptorPath}`);
}

function executeFixCode(string[] args) returns error? {
    return executeFixCommand(args, "auto-apply");
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
    string connectorOutputPath = resolveConnectorOutputPath();

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

    fixer:FixResult|fixer:BallerinaFixerError result = fixer:fixJavaNativeAdaptorErrors(
        connectorOutputPath,
        quietMode,
        autoYes,
        maxFixIterations
    );
    if result is fixer:BallerinaFixerError {
        io:println(string `Code fix failed: ${result.message()}`);
        return result;
    }

    io:println("Code fix command completed:");
    io:println(string `  success: ${result.success}`);
    io:println(string `  fixed: ${result.errorsFixed}`);
    io:println(string `  remaining: ${result.errorsRemaining}`);
    if !result.success && result.remainingFixes.length() > 0 {
        io:println("  issues:");
        foreach string issue in result.remainingFixes {
            io:println(string `    - ${issue}`);
        }
    }
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
    io:println("  modules/connector_generator/output/ballerina/client.bal");
    io:println("  modules/connector_generator/output/ballerina/types.bal");
    io:println("  modules/connector_generator/output/src/main/java/... (native adaptor)");
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
    io:println("Run code fixer on generated native adaptor output");
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
    io:println("  modules/connector_generator/output/ballerina/client.bal");
    io:println("  modules/connector_generator/output/ballerina/types.bal");
    io:println("  modules/connector_generator/output/src/main/java/... (native adaptor)");
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
    boolean enableCodeFixing = false;
    string fixMode = "auto-apply";
    int maxFixIterations = 3;
    foreach string arg in args.slice(1) {
        if arg == "quiet" || arg == "--quiet" || arg == "-q" {
            quietMode = true;
        } else if arg == "--fix-code" {
            enableCodeFixing = true;
        } else if arg == "--fix-report-only" {
            enableCodeFixing = true;
            fixMode = "report-only";
        } else if arg.startsWith("--fix-iterations=") {
            string value = arg.substring(17);
            int|error parsed = int:fromString(value);
            if parsed is int {
                maxFixIterations = parsed;
            }
        }
    }

    if !quietMode {
        io:println("===== Phase 1: SDK Analysis =====");
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

    if !quietMode {
        io:println("");
        io:println("===== Phase 2: API Specification Generation =====");
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

    if !quietMode {
        io:println("");
        io:println("===== Phase 3: Connector Generation =====");
        io:println(string `  → IR: ${irPath}`);
        io:println(string `  → API Spec: ${specPath}`);
    }

    connector:ConnectorGeneratorConfig connectorConfig = {
        metadataPath: metadataPath,
        irPath: irPath,
        apiSpecPath: specPath,
        outputDir: CONNECTOR_OUTPUT_DIR,
        quietMode: quietMode,
        enableCodeFixing: enableCodeFixing,
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

    if !quietMode {
        io:println("");
        io:println("===== Pipeline Complete =====");
        io:println(string `Metadata: ${metadataPath}`);
        io:println(string `IR: ${irPath}`);
        io:println(string `Specification: ${genResult.specificationPath}`);
        io:println(string `Connector client: ${connectorResult.clientPath}`);
        io:println(string `Connector types: ${connectorResult.typesPath}`);
        io:println(string `Native adaptor: ${connectorResult.nativeAdaptorPath}`);
        if connectorResult.codeFixingRan {
            io:println(string `Code fixing: ${connectorResult.codeFixingSuccess ? "success" : "partial/failed"}`);
        }
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
        javadocPath: javadocJar,
        quietMode: quietMode
    };

    int i = 0;
    while i < args.length() {
        string arg = args[i];
        match arg {
            "yes" | "--yes" | "-y" => {
                config.autoYes = true;
            }
            "quiet" | "--quiet" | "-q" => {
                config.quietMode = true;
            }
            "include-deprecated" | "--include-deprecated" => {
                config.includeDeprecated = true;
            }
            "include-internal" | "--include-internal" => {
                config.filterInternal = false;
            }
            "include-non-public" | "--include-non-public" => {
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
                            "exclude-packages" | "--exclude-packages" => {
                                if value.length() > 0 {
                                    config.excludePackages = regex:split(value, ",")
                                        .map(pkg => pkg.trim())
                                        .filter(pkg => pkg.length() > 0);
                                }
                            }
                            "include-packages" | "--include-packages" => {
                                if value.length() > 0 {
                                    config.includePackages = regex:split(value, ",")
                                        .map(pkg => pkg.trim())
                                        .filter(pkg => pkg.length() > 0);
                                }
                            }
                            "max-depth" | "--max-depth" => {
                                int|error depth = int:fromString(value);
                                if depth is int {
                                    config.maxDependencyDepth = depth;
                                }
                            }
                            "methods-to-list" | "--methods-to-list" => {
                                int|error methods = int:fromString(value);
                                if methods is int {
                                    config.methodsToList = methods;
                                }
                            }
                            "sources" | "--sources" => {
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

function resolveConnectorOutputPath() returns string {
    string cwd = os:getEnv("PWD");
    return string `${cwd}/${CONNECTOR_OUTPUT_DIR}`;
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
    io:println("  fix-code   Run Java native-adaptor fixer on connector output");
    io:println("  fix-report-only  Run fixer diagnostics without applying fixes");
    io:println("  pipeline   Run full pipeline end-to-end with fixed paths");
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
    io:println("EXAMPLE:");
    io:println("  bal run -- analyze s3-2.4.0 quiet");
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
    io:println("  modules/connector_generator/output/... (ballerina + native java)");
    io:println();
    io:println("OPTIONS:");
    io:println("  --fix-code              Enable post-generation Java native-adaptor fixing");
    io:println("  --fix-report-only       Detect/report Java issues without applying fixes");
    io:println("  --fix-iterations=<n>    Maximum fixer iterations (default: 3)");
    io:println("  quiet                   Minimal logging output");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- pipeline s3-2.4.0 --fix-code");
    io:println();
}
