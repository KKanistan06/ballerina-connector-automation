import ballerina/file;
import ballerina/io;

# Write generated connector files to module-local output directories.
#
# + clientCode - generated Ballerina client class code 
# + typesCode - generated Ballerina types code
# + javaAdaptorCode - generated Java native adaptor code
# + sdkToken - root client name from SDK metadata, used for naming files and classes
# + outputDir - root output directory for generated artifacts
# + return - paths of the written files or an error if writing fails
public function writeConnectorArtifacts(string clientCode, string typesCode, string javaAdaptorCode,
        string sdkToken, string outputDir = "modules/connector_generator/output")
        returns record {|string clientPath; string typesPath; string nativePath;|}|error {
    return writeConnectorArtifactsWithNames(
        clientCode,
        typesCode,
        javaAdaptorCode,
        string `${sdkToken}_client.bal`,
        string `${sdkToken}_types.bal`,
        string `src/main/java/Native${sdkToken}Adaptor.java`,
        outputDir
    );
}

# Write generated connector files to module-local output directories with explicit file names.
#
# + clientCode - generated Ballerina client class code
# + typesCode - generated Ballerina types code
# + javaAdaptorCode - generated Java native adaptor code
# + clientFileName - output client file name
# + typesFileName - output types file name
# + nativeRelativePath - native adaptor path relative to output root (typically under src/main/java)
# + outputDir - root output directory for generated artifacts
# + return - paths of the written files or an error if writing fails
public function writeConnectorArtifactsWithNames(string clientCode, string typesCode, string javaAdaptorCode,
        string clientFileName, string typesFileName,
        string nativeRelativePath, string outputDir = "modules/connector_generator/output")
        returns record {|string clientPath; string typesPath; string nativePath;|}|error {
    string rootDir = outputDir.trim().length() == 0 ? "modules/connector_generator/output" : outputDir;
    string ballerinaDir = string `${rootDir}/ballerina`;
    string nativePath = toNativeSourcePath(rootDir, nativeRelativePath);
    string nativeDir = parentDir(nativePath);

    check ensureDir(ballerinaDir);
    check ensureDir(nativeDir);
    check ensureNativeInteropBuildFiles(rootDir);
    check ensureBallerinaPackageFiles(ballerinaDir);

    string clientPath = string `${ballerinaDir}/${clientFileName}`;
    string typesPath = string `${ballerinaDir}/${typesFileName}`;

    check io:fileWriteString(clientPath, clientCode);
    check io:fileWriteString(typesPath, typesCode);
    check io:fileWriteString(nativePath, javaAdaptorCode);

    return {
        clientPath: clientPath,
        typesPath: typesPath,
        nativePath: nativePath
    };
}

function ensureDir(string dirPath) returns error? {
    boolean exists = check file:test(dirPath, file:EXISTS);
    if !exists {
        check file:createDir(dirPath, file:RECURSIVE);
    }
}

function toNativeSourcePath(string rootDir, string nativeRelativePath) returns string {
    string trimmed = nativeRelativePath.trim();
    if trimmed.length() == 0 {
        return string `${rootDir}/src/main/java/NativeAdaptor.java`;
    }
    if trimmed.startsWith("src/main/java/") {
        return string `${rootDir}/${trimmed}`;
    }
    if trimmed.endsWith(".java") {
        return string `${rootDir}/src/main/java/${trimmed}`;
    }
    return string `${rootDir}/src/main/java/${trimmed}.java`;
}

function parentDir(string path) returns string {
    int? idx = path.lastIndexOf("/");
    if idx is int && idx > 0 {
        return path.substring(0, idx);
    }
    return ".";
}

function ensureNativeInteropBuildFiles(string rootDir) returns error? {
    string settingsGradlePath = string `${rootDir}/settings.gradle`;
    string buildGradlePath = string `${rootDir}/build.gradle`;

    boolean settingsExists = check file:test(settingsGradlePath, file:EXISTS);
    if !settingsExists {
        check io:fileWriteString(settingsGradlePath, "rootProject.name = 'generated-native-adaptor'\n");
    }

    boolean buildExists = check file:test(buildGradlePath, file:EXISTS);
    if !buildExists {
        string buildGradle = string `plugins {
    id 'java'
}

repositories {
    mavenCentral()
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

dependencies {
    implementation "io.ballerina:ballerina-runtime:2201.13.1"
    implementation platform("software.amazon.awssdk:bom:2.31.66")
    implementation "software.amazon.awssdk:sqs"
}
`;
        check io:fileWriteString(buildGradlePath, buildGradle);
    }
}

function ensureBallerinaPackageFiles(string ballerinaDir) returns error? {
    string tomlPath = string `${ballerinaDir}/Ballerina.toml`;
    boolean tomlExists = check file:test(tomlPath, file:EXISTS);
    if !tomlExists {
        string ballerinaToml = string `[package]
org = "generated"
name = "connector"
version = "0.1.0"
distribution = "2201.13.1"

[dependencies]
"ballerina/jballerina.java" = "0.0.0"
`;
        check io:fileWriteString(tomlPath, ballerinaToml);
    }
}
