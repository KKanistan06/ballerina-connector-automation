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
    check ensureNativeInteropBuildFiles(rootDir, javaAdaptorCode);
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

function ensureNativeInteropBuildFiles(string rootDir, string javaAdaptorCode) returns error? {
    string settingsGradlePath = string `${rootDir}/settings.gradle`;
    string buildGradlePath = string `${rootDir}/build.gradle`;

    boolean settingsExists = check file:test(settingsGradlePath, file:EXISTS);
    if !settingsExists {
        check io:fileWriteString(settingsGradlePath, "rootProject.name = 'generated-native-adaptor'\n");
    }

    boolean buildExists = check file:test(buildGradlePath, file:EXISTS);
    if !buildExists {
        string buildGradle = generateBuildGradleContent(rootDir, javaAdaptorCode);
        check io:fileWriteString(buildGradlePath, buildGradle);
        return;
    }

    string existingBuildGradle = check io:fileReadString(buildGradlePath);
    boolean hasFatJar = (existingBuildGradle.includes("archiveFileName = 'generated-native-adaptor.jar'") ||
        existingBuildGradle.includes("archiveName = 'generated-native-adaptor.jar'")) &&
        existingBuildGradle.includes("configurations.runtimeClasspath");
    if !hasFatJar {
        string fatJarBlock = string `

    jar {
        if (project.gradle.gradleVersion.tokenize('.')[0].toInteger() >= 5) {
        archiveFileName = 'generated-native-adaptor.jar'
    } else {
        archiveName = 'generated-native-adaptor.jar'
    }
    from {
        configurations.runtimeClasspath.collect { it.isDirectory() ? it : zipTree(it) }
    }
}
`;
        check io:fileWriteString(buildGradlePath, existingBuildGradle.trim() + fatJarBlock + "\n");
    }
}

function generateBuildGradleContent(string rootDir, string javaAdaptorCode) returns string {
    string? sdkVersion = inferSdkVersionFromRootDir(rootDir);
    string? sdkArtifact = inferSdkArtifactFromRootDir(rootDir);
    string? sdkGroupId = inferSdkGroupIdFromImports(javaAdaptorCode, sdkArtifact);

    string dependencyLines = "    // Ballerina runtime\n" +
        "    implementation 'org.ballerinalang:ballerina-runtime:2201.12.2'\n";

    if sdkGroupId is string && sdkArtifact is string && sdkVersion is string {
        dependencyLines += "\n    // Connector dependency (from analyzed SDK)\n";
        dependencyLines += string `    implementation '${sdkGroupId}:${sdkArtifact}:${sdkVersion}'\n`;
    }

    return string `plugins {
    id 'java'
}

repositories {
    mavenLocal()

    maven {
        url = 'https://maven.wso2.org/nexus/content/groups/wso2-public/'
    }

    maven {
        url = 'https://repo.maven.apache.org/maven2'
    }

    maven {
        url = 'https://maven.pkg.github.com/ballerina-platform/ballerina-lang'
        credentials {
            username = project.findProperty("gpr.user") ?: System.getenv("packageUser") ?: ""
            password = project.findProperty("gpr.key") ?: System.getenv("packagePAT") ?: ""
        }
    }

    maven {
        url = 'https://maven.pkg.github.com/ballerina-platform/ballerina-library'
        credentials {
            username = project.findProperty("gpr.user") ?: System.getenv("packageUser") ?: ""
            password = project.findProperty("gpr.key") ?: System.getenv("packagePAT") ?: ""
        }
    }
}

sourceCompatibility = '21'
targetCompatibility = '21'

tasks.withType(JavaCompile) {
    options.encoding = 'UTF-8'
    options.compilerArgs = ['-source', '21', '-target', '21']
}

dependencies {
${dependencyLines}}

jar {
    manifest {
        attributes 'Implementation-Title': 'generated-native-adaptor'
    }
    if (project.gradle.gradleVersion.tokenize('.')[0].toInteger() >= 5) {
        archiveFileName = 'generated-native-adaptor.jar'
    } else {
        archiveName = 'generated-native-adaptor.jar'
    }
    from {
        configurations.runtimeClasspath.collect { it.isDirectory() ? it : zipTree(it) }
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
}`;
}

function inferSdkArtifactFromRootDir(string rootDir) returns string? {
    int? slashIndex = rootDir.lastIndexOf("/");
    string dirName = slashIndex is int ? rootDir.substring(<int>slashIndex + 1) : rootDir;

    int? dashIndex = dirName.lastIndexOf("-");
    if !(dashIndex is int) || dashIndex <= 0 {
        return;
    }

    return dirName.substring(0, <int>dashIndex);
}

function inferSdkGroupIdFromImports(string javaAdaptorCode, string? sdkArtifact) returns string? {
    string[] imports = extractExternalImports(javaAdaptorCode);
    if imports.length() == 0 {
        return;
    }

    if sdkArtifact is string {
        string marker = string `.${sdkArtifact}.`;
        foreach string importPath in imports {
            int? markerIndex = importPath.indexOf(marker);
            if markerIndex is int && markerIndex > 0 {
                string group = importPath.substring(0, <int>markerIndex);
                if group.endsWith(".services") {
                    return group.substring(0, group.length() - 9);
                }
                return group;
            }
        }
    }

    return firstSegments(imports[0], 2);
}

function extractExternalImports(string javaAdaptorCode) returns string[] {
    string[] imports = [];
    string remaining = javaAdaptorCode;

    while true {
        int? importIndex = remaining.indexOf("import ");
        if !(importIndex is int) {
            break;
        }

        string afterImport = remaining.substring(<int>importIndex + 7);
        int? semiIndex = afterImport.indexOf(";");
        if !(semiIndex is int) {
            break;
        }

        string importPath = afterImport.substring(0, <int>semiIndex).trim();
        if isExternalImport(importPath) && !containsStringValue(imports, importPath) {
            imports.push(importPath);
        }

        remaining = afterImport.substring(<int>semiIndex + 1);
    }

    return imports;
}

function isExternalImport(string importPath) returns boolean {
    if importPath.startsWith("static ") {
        return false;
    }
    return !importPath.startsWith("java.") &&
        !importPath.startsWith("javax.") &&
        !importPath.startsWith("jakarta.") &&
        !importPath.startsWith("io.ballerina.") &&
        !importPath.startsWith("org.ballerinalang.");
}

function firstSegments(string value, int count) returns string {
    int segmentCount = 0;
    foreach int i in 0 ..< value.length() {
        string ch = value.substring(i, i + 1);
        if ch == "." {
            segmentCount += 1;
            if segmentCount == count {
                return value.substring(0, i);
            }
        }
    }
    return value;
}

function inferSdkVersionFromRootDir(string rootDir) returns string? {
    int? slashIndex = rootDir.lastIndexOf("/");
    string dirName = slashIndex is int ? rootDir.substring(<int>slashIndex + 1) : rootDir;

    int? dashIndex = dirName.lastIndexOf("-");
    if !(dashIndex is int) || dashIndex <= 0 || (<int>dashIndex + 1) >= dirName.length() {
        return;
    }

    string version = dirName.substring(<int>dashIndex + 1);
    if isLikelyVersion(version) {
        return version;
    }

    return;
}

function containsStringValue(string[] items, string expected) returns boolean {
    foreach string item in items {
        if item == expected {
            return true;
        }
    }

    return false;
}

function isLikelyVersion(string value) returns boolean {
    if value.length() == 0 {
        return false;
    }

    foreach int i in 0 ..< value.length() {
        string ch = value.substring(i, i + 1);
        if !"0123456789.".includes(ch) {
            return false;
        }
    }

    return true;
}

function ensureBallerinaPackageFiles(string ballerinaDir) returns error? {
    string tomlPath = string `${ballerinaDir}/Ballerina.toml`;
    string readmePath = string `${ballerinaDir}/README.md`;
    check ensureGeneratedConnectorReadme(readmePath);
    boolean tomlExists = check file:test(tomlPath, file:EXISTS);
    if !tomlExists {
        string ballerinaToml = string `[package]
org = "generated"
name = "connector"
version = "0.1.0"
distribution = "2201.13.1"

[dependencies]
"ballerina/jballerina.java" = "0.0.0"

[[platform.java21.dependency]]
path = "../build/libs/generated-native-adaptor.jar"
`;
        check io:fileWriteString(tomlPath, ballerinaToml);
        return;
    }

    string existingToml = check io:fileReadString(tomlPath);
    boolean hasJavaDep = existingToml.includes("\"ballerina/jballerina.java\"");
    boolean hasPlatformDep = existingToml.includes("[[platform.java21.dependency]]") &&
        existingToml.includes("../build/libs/");

    if hasJavaDep && hasPlatformDep {
        return;
    }

    string updatedToml = existingToml.trim();
    if !hasJavaDep {
        if !updatedToml.includes("[dependencies]") {
            updatedToml += "\n\n[dependencies]\n";
        }
        updatedToml += "\n\"ballerina/jballerina.java\" = \"0.0.0\"\n";
    }

    if !hasPlatformDep {
        updatedToml += "\n[[platform.java21.dependency]]\n";
        updatedToml += "path = \"../build/libs/generated-native-adaptor.jar\"\n";
    }

    check io:fileWriteString(tomlPath, updatedToml + "\n");
}

function ensureGeneratedConnectorReadme(string readmePath) returns error? {
    boolean readmeExists = check file:test(readmePath, file:EXISTS);
    if !readmeExists {
        string defaultReadme = "# Generated Connector\n\nThis package is auto-generated by connector automation.\n";
        check io:fileWriteString(readmePath, defaultReadme);
    }
}
