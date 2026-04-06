import ballerina/io;
import ballerina/time;
import wso2/connector_automation.sdkanalyzer as analyzer;
import wso2/connector_automation.api_specification_generator as api;
import wso2/connector_automation.code_fixer as fixer;

# Generate connector artifacts from metadata JSON, IR JSON, and API spec.
#
# + config - Connector generator configuration, including input paths and generation options.
# + return - Connector generation result with artifact paths and generation stats, or error on failure.
public function generateConnector(ConnectorGeneratorConfig config)
        returns ConnectorGeneratorResult|ConnectorGeneratorError {
    time:Utc startTime = time:utcNow();

    if !isAnthropicConfigured() {
        return error ConnectorGeneratorError("ANTHROPIC_API_KEY environment variable not set. " +
            "LLM is mandatory for connector generation.");
    }

    ConnectorGenerationInputs|error loaded = loadInputs(config);
    if loaded is error {
        return error ConnectorGeneratorError(string `Failed to load inputs: ${loaded.message()}`, loaded);
    }

    if !config.quietMode {
        io:println("Step 1/4: Generating connector bundle via LLM...");
    }
    GeneratedConnectorBundle|error bundleResult = generateConnectorBundleViaLLM(loaded, config);
    if bundleResult is error {
        return error ConnectorGeneratorError(
            string `LLM connector generation failed: ${bundleResult.message()}`,
            bundleResult);
    }
    GeneratedConnectorBundle bundle = bundleResult;

    if !config.quietMode {
        io:println("Step 2/4: Validating generated connector bundle...");
    }
    error? validationError = validateGeneratedBundle(bundle, loaded);
    if validationError is error {
        return error ConnectorGeneratorError(
            string `Generated connector failed validation: ${validationError.message()}`,
            validationError);
    }

    string clientFileName = "client.bal";
    string typesFileName = "types.bal";
    string nativeSourcePath = normalizeNativeSourcePath(bundle.nativeAdaptorFilePath, bundle.nativeAdaptorClassName,
        "NativeAdaptor");

    if !config.quietMode {
        io:println("Step 3/4: Writing generated connector artifacts...");
    }
    record {|string clientPath; string typesPath; string nativePath;|}|error writeResult =
        writeConnectorArtifactsWithNames(
            bundle.clientBal,
            bundle.typesBal,
            bundle.nativeAdaptorJava,
            clientFileName,
            typesFileName,
            nativeSourcePath,
            config.outputDir);
    if writeResult is error {
        return error ConnectorGeneratorError(string `Failed to write connector artifacts: ${writeResult.message()}`,
            writeResult);
    }

    int mapped = countResolvedMappings(bundle.methodMappings, loaded.metadata.rootClient.methods);

    time:Utc endTime = time:utcNow();
    int durationMs = <int>(time:utcDiffSeconds(endTime, startTime) * 1000);

    if !config.quietMode {
        io:println("Step 4/4: Connector generation completed successfully.");
    }

    boolean codeFixingRan = false;
    boolean codeFixingSuccess = false;

    if config.enableCodeFixing {
        codeFixingRan = true;
        if !config.quietMode {
            io:println("Running post-generation native adaptor code fixing...");
        }

        boolean autoYes = config.fixMode != "report-only";
        fixer:FixResult|fixer:BallerinaFixerError fixResult = fixer:fixJavaNativeAdaptorErrors(config.outputDir,
            config.quietMode, autoYes, config.maxFixIterations);
        if fixResult is fixer:BallerinaFixerError {
            return error ConnectorGeneratorError(string `Code fixing failed: ${fixResult.message()}`, fixResult);
        }
        codeFixingSuccess = fixResult.success;
    }

    return {
        success: true,
        clientPath: writeResult.clientPath,
        typesPath: writeResult.typesPath,
        nativeAdaptorPath: writeResult.nativePath,
        mappedMethodCount: mapped,
        specMethodCount: loaded.parsedSpec.clientMethods.length(),
        durationMs: durationMs,
        codeFixingRan: codeFixingRan,
        codeFixingSuccess: codeFixingSuccess
    };
}

# CLI entrypoint for connector command.
#
# + args - Command-line arguments passed to the connector generator, including input paths and options.
# + return - Error on failure, or void on success.
public function executeConnectorGenerator(string[] args) returns error? {
    if args.length() < 4 {
        printConnectorUsage();
        return;
    }

    int idx = 1;
    if args[0] != "connector" {
        idx = 0;
    }

    if args.length() < idx + 3 {
        printConnectorUsage();
        return;
    }

    ConnectorGeneratorConfig config = {
        metadataPath: args[idx],
        irPath: args[idx + 1],
        apiSpecPath: args[idx + 2],
        outputDir: args.length() > idx + 3 ? args[idx + 3] : "./output"
    };

    int optionStart = args.length() > idx + 3 ? idx + 4 : idx + 3;
    foreach string arg in args.slice(optionStart) {
        if arg == "quiet" || arg == "--quiet" || arg == "-q" {
            config.quietMode = true;
        } else if arg == "--fix-code" {
            config.enableCodeFixing = true;
        } else if arg == "--fix-report-only" {
            config.enableCodeFixing = true;
            config.fixMode = "report-only";
        } else if arg.startsWith("--fix-iterations=") {
            string val = arg.substring(17);
            int|error parsed = int:fromString(val);
            if parsed is int {
                config.maxFixIterations = parsed;
            }
        }
    }

    ConnectorGeneratorResult|ConnectorGeneratorError result = generateConnector(config);
    if result is ConnectorGeneratorError {
        io:println(string `Connector generation failed: ${result.message()}`);
        return result;
    }

    io:println(string `Connector generated:`);
    io:println(string `  client: ${result.clientPath}`);
    io:println(string `  types:  ${result.typesPath}`);
    io:println(string `  native: ${result.nativeAdaptorPath}`);
    io:println(string `  mapped methods: ${result.mappedMethodCount}`);
    if result.codeFixingRan {
        io:println(string `  code fixing: ${result.codeFixingSuccess ? "success" : "partial/failed"}`);
    }
}

function loadInputs(ConnectorGeneratorConfig config) returns ConnectorGenerationInputs|error {
    string metadataText = check io:fileReadString(config.metadataPath);
    json|error metadataJson = metadataText.fromJsonString();
    if metadataJson is error {
        return error(string `Invalid metadata JSON: ${metadataJson.message()}`, metadataJson);
    }
    analyzer:StructuredSDKMetadata|error metadata = metadataJson.cloneWithType(analyzer:StructuredSDKMetadata);
    if metadata is error {
        return error(string `Metadata JSON does not match schema: ${metadata.message()}`, metadata);
    }

    string irText = check io:fileReadString(config.irPath);
    json|error irJson = irText.fromJsonString();
    if irJson is error {
        return error(string `Invalid IR JSON: ${irJson.message()}`, irJson);
    }
    api:IntermediateRepresentation|error ir = irJson.cloneWithType(api:IntermediateRepresentation);
    if ir is error {
        return error(string `IR JSON does not match schema: ${ir.message()}`, ir);
    }

    ParsedApiSpec|error parsedSpec = parseApiSpec(config.apiSpecPath);
    if parsedSpec is error {
        return error(string `Failed to parse API spec: ${parsedSpec.message()}`, parsedSpec);
    }

    string apiSpecText = check io:fileReadString(config.apiSpecPath);

    return {
        metadata: metadata,
        ir: ir,
        parsedSpec: parsedSpec,
        metadataJsonText: metadataText,
        irJsonText: irText,
        apiSpecText: apiSpecText
    };
}

function generateConnectorBundleViaLLM(ConnectorGenerationInputs loaded,
        ConnectorGeneratorConfig config) returns GeneratedConnectorBundle|error {
    AnthropicConfig anthropicConfig = check getAnthropicConfig(
        config.maxTokens,
        config.enableExtendedThinking,
        config.thinkingBudgetTokens
    );

    string systemPrompt = getConnectorGenerationSystemPrompt();
    string userPrompt = getConnectorGenerationUserPrompt(
        loaded.metadataJsonText,
        loaded.irJsonText,
        loaded.apiSpecText,
        config.sdkVersionHint
    );

    json llmResponse = check callAnthropicAPI(anthropicConfig, systemPrompt, userPrompt);
    string responseText = extractResponseText(llmResponse);
    string bundleJsonText = check extractJsonFromResponse(responseText);

    json|error parsed = bundleJsonText.fromJsonString();
    if parsed is error {
        return error(string `LLM bundle JSON parse failed: ${parsed.message()}`);
    }
    GeneratedConnectorBundle|error bundle = parsed.cloneWithType(GeneratedConnectorBundle);
    if bundle is error {
        return error(string `LLM bundle schema mismatch: ${bundle.message()}`);
    }
    return bundle;
}

function validateGeneratedBundle(GeneratedConnectorBundle bundle,
        ConnectorGenerationInputs loaded) returns error? {
    if bundle.clientBal.trim().length() == 0 || bundle.typesBal.trim().length() == 0 ||
            bundle.nativeAdaptorJava.trim().length() == 0 {
        return error("Generated artifact code blocks must not be empty");
    }

    string[] specMethodNames = [];
    foreach SpecMethodSignature method in loaded.parsedSpec.clientMethods {
        specMethodNames.push(method.name);
    }

    foreach string specMethodName in specMethodNames {
        int occurrences = 0;
        foreach GeneratedMethodMapping mapping in bundle.methodMappings {
            if mapping.specMethod == specMethodName {
                occurrences += 1;
            }
        }
        if occurrences != 1 {
            return error(string `Expected exactly one mapping for '${specMethodName}', found ${occurrences}`);
        }
    }

    foreach GeneratedMethodMapping mapping in bundle.methodMappings {
        if !hasMethodByName(mapping.javaMethod, loaded.metadata.rootClient.methods) {
            return error(string `Mapped Java method not found in metadata root client: ${mapping.javaMethod}`);
        }
        if mapping.confidence < 0.0d || mapping.confidence > 1.0d {
            return error(string `Invalid mapping confidence for '${mapping.specMethod}': ${mapping.confidence}`);
        }
        foreach ParameterBinding binding in mapping.parameterBindings {
            if binding.specParam.trim().length() == 0 || binding.javaParam.trim().length() == 0 {
                return error(string `Invalid empty parameter binding in mapping '${mapping.specMethod}'`);
            }
        }
    }

    foreach string methodName in specMethodNames {
        if !bundle.clientBal.includes(string `function ${methodName}(`) {
            return error(string `Generated clientBal is missing method signature for '${methodName}'`);
        }
        if !bundle.nativeAdaptorJava.includes(string ` ${methodName}(`) {
            return error(string `Generated nativeAdaptorJava is missing method '${methodName}'`);
        }
    }

    string[] referencedTypeNames = collectReferencedTypeNamesFromSpec(loaded.parsedSpec);
    foreach string typeName in referencedTypeNames {
        if !hasDeclaredTypeOrEnum(bundle.typesBal, typeName) {
            return error(string `Generated typesBal is missing type declaration for '${typeName}' referenced by API spec signatures`);
        }
    }

    string expectedNativePath = deriveNativeSourcePathFromClass(bundle.nativeAdaptorClassName);
    if bundle.nativeAdaptorFilePath.trim() != expectedNativePath {
        return error(string `nativeAdaptorFilePath must be '${expectedNativePath}', found '${bundle.nativeAdaptorFilePath}'`);
    }

    string[] requiredNativeImports = [
        "import io.ballerina.runtime.api.Environment;",
        "import io.ballerina.runtime.api.creators.ErrorCreator;",
        "import io.ballerina.runtime.api.creators.ValueCreator;",
        "import io.ballerina.runtime.api.utils.StringUtils;",
        "import io.ballerina.runtime.api.values.BObject;"
    ];
    foreach string requiredImport in requiredNativeImports {
        if !bundle.nativeAdaptorJava.includes(requiredImport) {
            return error(string `Generated nativeAdaptorJava missing required import/prefix: ${requiredImport}`);
        }
    }

    if !bundle.validation.allSpecMethodsMapped || bundle.validation.unmappedSpecMethods.length() > 0 {
        return error("LLM validation indicates unmapped API spec methods");
    }
    if bundle.validation.signatureMismatches.length() > 0 {
        return error("LLM validation indicates signature mismatches");
    }
    if bundle.validation.typeReferenceErrors.length() > 0 {
        return error("LLM validation indicates type reference errors");
    }
}

function countResolvedMappings(GeneratedMethodMapping[] mappings,
        analyzer:MethodInfo[] methods) returns int {
    int count = 0;
    foreach GeneratedMethodMapping mapping in mappings {
        if hasMethodByName(mapping.javaMethod, methods) {
            count += 1;
        }
    }
    return count;
}

function hasMethodByName(string methodName, analyzer:MethodInfo[] methods) returns boolean {
    foreach analyzer:MethodInfo method in methods {
        if method.name == methodName {
            return true;
        }
    }
    return false;
}

function normalizeBallerinaFileName(string suggestedName, string suffix) returns string {
    string trimmed = suggestedName.trim();
    if trimmed.length() == 0 {
        return string `generated_${suffix}`;
    }
    if trimmed.endsWith(".bal") {
        return trimmed;
    }
    return string `${trimmed}.bal`;
}

function normalizeJavaFileName(string className, string fallbackBaseName) returns string {
    string trimmed = className.trim();
    string base = trimmed.length() > 0 ? trimmed : fallbackBaseName;
    if base.endsWith(".java") {
        return base;
    }
    return string `${base}.java`;
}

function deriveNativeSourcePathFromClass(string nativeAdaptorClassName) returns string {
    string className = nativeAdaptorClassName.trim();
    if className.length() == 0 {
        return "src/main/java/NativeAdaptor.java";
    }
    string path = "";
    string remaining = className;
    while true {
        int? idx = remaining.indexOf(".");
        if idx is int {
            string token = remaining.substring(0, idx);
            path = path.length() == 0 ? token : string `${path}/${token}`;
            remaining = remaining.substring(idx + 1);
        } else {
            path = path.length() == 0 ? remaining : string `${path}/${remaining}`;
            break;
        }
    }
    return string `src/main/java/${path}.java`;
}

function normalizeNativeSourcePath(string suggestedPath, string nativeAdaptorClassName,
        string fallbackBaseName) returns string {
    string trimmed = suggestedPath.trim();
    if trimmed.length() > 0 {
        if trimmed.startsWith("src/main/java/") {
            if trimmed.endsWith(".java") {
                return trimmed;
            }
            return string `${trimmed}.java`;
        }
        if trimmed.endsWith(".java") {
            return string `src/main/java/${trimmed}`;
        }
        return string `src/main/java/${trimmed}.java`;
    }

    string className = nativeAdaptorClassName.trim();
    if className.length() > 0 {
        return deriveNativeSourcePathFromClass(className);
    }

    string fallbackName = normalizeJavaFileName(fallbackBaseName, fallbackBaseName);
    return string `src/main/java/${fallbackName}`;
}

function collectReferencedTypeNamesFromSpec(ParsedApiSpec parsedSpec) returns string[] {
    string[] names = [];
    foreach SpecMethodSignature method in parsedSpec.clientMethods {
        foreach SpecMethodParameter specParameter in method.parameters {
            addIdentifierTypes(specParameter.'type, names);
        }
        addIdentifierTypes(method.returnType, names);
    }
    return names;
}

function addIdentifierTypes(string typeExpr, string[] names) {
    string token = "";
    foreach int i in 0 ..< typeExpr.length() {
        string ch = typeExpr.substring(i, i + 1);
        if isIdentifierChar(ch) {
            token += ch;
        } else {
            pushTypeToken(token, names);
            token = "";
        }
    }
    pushTypeToken(token, names);
}

function isIdentifierChar(string ch) returns boolean {
    if ch.length() != 1 {
        return false;
    }
    byte b = ch.toBytes()[0];
    return (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95;
}

function pushTypeToken(string token, string[] names) {
    string trimmed = token.trim();
    if trimmed.length() == 0 {
        return;
    }
    if isBuiltInTypeToken(trimmed) {
        return;
    }
    int codePoint = <int>trimmed.toCodePointInts()[0];
    if !(codePoint >= 65 && codePoint <= 90) {
        return;
    }
    if !containsString(names, trimmed) {
        names.push(trimmed);
    }
}

function containsString(string[] values, string target) returns boolean {
    foreach string value in values {
        if value == target {
            return true;
        }
    }
    return false;
}

function isBuiltInTypeToken(string token) returns boolean {
    return token == "string" || token == "int" || token == "boolean" || token == "decimal" || token == "float" ||
        token == "byte" || token == "xml" || token == "json" || token == "map" || token == "record" ||
        token == "error" || token == "readonly" || token == "future" || token == "stream" || token == "table" ||
        token == "typedesc" || token == "any" || token == "anydata" || token == "never" || token == "object";
}

function hasDeclaredTypeOrEnum(string typesBal, string typeName) returns boolean {
    return typesBal.includes(string `type ${typeName} `) ||
        typesBal.includes(string `type ${typeName} record`) ||
        typesBal.includes(string `enum ${typeName} `) ||
        typesBal.includes(string `enum ${typeName} {`);
}

public function printConnectorUsage() {
    io:println();
    io:println("Generate connector artifacts from metadata, IR and API spec");
    io:println();
    io:println("USAGE:");
    io:println("  bal run -- connector <metadata-json> <ir-json> <api-spec-bal> [output-dir] [options]");
    io:println();
    io:println("OPTIONS:");
    io:println("  --fix-code              Enable post-generation code fixing for native adaptor Java");
    io:println("  --fix-report-only       Run fixer diagnostics but do not apply changes");
    io:println("  --fix-iterations=<n>    Maximum fixer iterations (default: 3)");
    io:println("  --quiet, -q             Minimal logging");
    io:println();
    io:println("EXAMPLE:");
    io:println("  bal run -- connector path/to/metadata.json " +
        "path/to/ir.json " +
        "path/to/api_spec.bal ./output --fix-code");
    io:println();
}
