import wso2/connector_automator.sdkanalyzer as analyzer;

# Build Java native adaptor source from method mappings.
#
# + mappings - Method mappings between API spec methods and metadata-described native methods, used to generate method bodies that invoke the correct underlying native methods. 
# + metadata - Structured native-library metadata, used to get the root client name for native adaptor generation.
# + return - Generated Java source code for the native adaptor class, with method stubs for each mapped API spec method.
public function buildNativeAdaptorJava(MethodMapping[] mappings,
        analyzer:StructuredSDKMetadata metadata) returns string {
    string sdkClientName = metadata.rootClient.simpleName;
    string packageLine = "package io.ballerina.connector.automator.connectorgenerator;";
    string[] lines = [
        packageLine,
        "",
        string `public class Native${sdkClientName}Adaptor {`,
        string `    private final ${sdkClientName} sdkClient;`,
        "",
        string `    public Native${sdkClientName}Adaptor() {`,
        "        this.sdkClient = null;",
        "    }"
    ];

    foreach MethodMapping mapping in mappings {
        SpecMethodSignature specMethod = mapping.specMethod;
        string javaMethodName = specMethod.name;
        analyzer:MethodInfo? candidate = mapping.javaMethod;
        if candidate is analyzer:MethodInfo {
            javaMethodName = candidate.name;
        }
        lines.push("");
        lines.push(string `    public Object ${specMethod.name}(Object... args) {`);
        lines.push(string `        // mapped native method: ${javaMethodName}`);
        lines.push("        throw new UnsupportedOperationException(\"TODO: implement native adaptor invocation\");");
        lines.push("    }");
    }

    lines.push("}");
    return string:'join("\n", ...lines);
}

# Build method mappings by matching API spec names to metadata root client methods.
#
# + parsedSpec - Parsed API specification containing the methods to be mapped.
# + metadata - Structured native-library metadata, used to find matching methods.
# + return - Array of method mappings between API spec methods and metadata native methods.
public function buildMethodMappings(ParsedApiSpec parsedSpec,
        analyzer:StructuredSDKMetadata metadata) returns MethodMapping[] {
    MethodMapping[] mappings = [];
    foreach SpecMethodSignature specMethod in parsedSpec.clientMethods {
        analyzer:MethodInfo? javaMethod = findMatchingJavaMethod(specMethod.name, metadata.rootClient.methods);
        mappings.push({
            specMethod: specMethod,
            javaMethod: javaMethod
        });
    }
    return mappings;
}

function findMatchingJavaMethod(string name, analyzer:MethodInfo[] methods) returns analyzer:MethodInfo? {
    foreach analyzer:MethodInfo m in methods {
        if m.name == name {
            return m;
        }
    }
    foreach analyzer:MethodInfo m in methods {
        if m.name.equalsIgnoreCaseAscii(name) {
            return m;
        }
    }
    return ();
}
