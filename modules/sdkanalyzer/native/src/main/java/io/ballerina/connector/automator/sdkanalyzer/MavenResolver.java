// Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

package io.ballerina.connector.automator.sdkanalyzer;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.ArrayType;
import io.ballerina.runtime.api.types.MapType;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;

/**
 * Maven resolver for downloading JARs and parsing POMs from Maven Central.
 */
public class MavenResolver {

    private static final int BUFFER_SIZE = 8192;
    private static final int TIMEOUT = 30000; // 30 seconds
    private static final String DEFAULT_MAVEN_CENTRAL = "https://repo1.maven.org/maven2";
    
    // AWS SDK short-form mappings
    private static final Map<String, String[]> AWS_SDK_SHORTCUTS = new HashMap<>();
    static {
        AWS_SDK_SHORTCUTS.put("s3", new String[]{"software.amazon.awssdk", "s3"});
        AWS_SDK_SHORTCUTS.put("sqs", new String[]{"software.amazon.awssdk", "sqs"});
        AWS_SDK_SHORTCUTS.put("sns", new String[]{"software.amazon.awssdk", "sns"});
        AWS_SDK_SHORTCUTS.put("dynamodb", new String[]{"software.amazon.awssdk", "dynamodb"});
        AWS_SDK_SHORTCUTS.put("lambda", new String[]{"software.amazon.awssdk", "lambda"});
        AWS_SDK_SHORTCUTS.put("ec2", new String[]{"software.amazon.awssdk", "ec2"});
    }

    /**
     * Resolve Maven coordinate (short or full form) and download JAR with dependencies.
     * 
     * @param coordinate Maven coordinate (e.g., "s3:2.25.16" or "software.amazon.awssdk:s3:2.25.16")
     * @return BMap containing jarPath and dependency paths
     */
    public static Object resolveMavenArtifact(BString coordinate) {
        try {
            String coord = coordinate.getValue();
            System.err.println("INFO: Resolving Maven coordinate: " + coord);
            
            // Parse coordinate
            String[] parts = coord.split(":");
            String groupId, artifactId, version;
            
            switch (parts.length) {
                case 2 -> {
                    // Short form: "s3:2.25.16"
                    String shortName = parts[0];
                    version = parts[1];
                    if (AWS_SDK_SHORTCUTS.containsKey(shortName)) {
                        String[] mapping = AWS_SDK_SHORTCUTS.get(shortName);
                        groupId = mapping[0];
                        artifactId = mapping[1];
                        System.err.println("INFO: Expanded short form '" + shortName + "' to " +
                                groupId + ":" + artifactId);
                    } else {
                        return ErrorCreator.createError(StringUtils.fromString(
                                "Unknown short form: " + shortName + ". Use full coordinate like group:artifact:version"));
                    }
                }
                case 3 -> {
                    // Full form: "software.amazon.awssdk:s3:2.25.16"
                    groupId = parts[0];
                    artifactId = parts[1];
                    version = parts[2];
                }
                default -> {
                    return ErrorCreator.createError(StringUtils.fromString(
                            "Invalid Maven coordinate format. Use 's3:2.25.16' or 'group:artifact:version'"));
                }
            }
            
            // Create cache directory
            Path cacheDir = Files.createTempDirectory("maven-cache-");
            System.err.println("INFO: Using cache directory: " + cacheDir);
            
            // Download main JAR and dependencies
            List<String> allJars = downloadArtifactWithDependencies(
                groupId, artifactId, version, DEFAULT_MAVEN_CENTRAL, cacheDir, new HashSet<>(), 0);
            
            if (allJars.isEmpty()) {
                return ErrorCreator.createError(StringUtils.fromString(
                    "Failed to download artifact: " + groupId + ":" + artifactId + ":" + version));
            }
            
            // Create result map
            MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
            BMap<BString, Object> result = ValueCreator.createMapValue(mapType);
            
            result.put(StringUtils.fromString("mainJar"), StringUtils.fromString(allJars.get(0)));
            result.put(StringUtils.fromString("cacheDir"), StringUtils.fromString(cacheDir.toString()));
            result.put(StringUtils.fromString("groupId"), StringUtils.fromString(groupId));
            result.put(StringUtils.fromString("artifactId"), StringUtils.fromString(artifactId));
            result.put(StringUtils.fromString("version"), StringUtils.fromString(version));
            
            // Add all JAR paths as array
            BString[] jarPaths = allJars.stream()
                .map(StringUtils::fromString)
                .toArray(BString[]::new);
            result.put(StringUtils.fromString("allJars"), ValueCreator.createArrayValue(jarPaths));
            
            return result;
            
        } catch (Exception e) {
            return ErrorCreator.createError(
                StringUtils.fromString("Failed to resolve Maven artifact: " + e.getMessage()));
        }
    }
    
    /**
     * Download artifact and its runtime dependencies recursively.
     */
    private static List<String> downloadArtifactWithDependencies(
            String groupId, String artifactId, String version, 
            String baseUrl, Path cacheDir, Set<String> visited, int depth) throws Exception {
        
        List<String> jars = new ArrayList<>();
        String key = groupId + ":" + artifactId + ":" + version;
        
        // Avoid cycles and limit depth
        if (visited.contains(key) || depth > 3) {
            return jars;
        }
        visited.add(key);
        
        // Download main JAR
        String groupPath = groupId.replace('.', '/');
        String jarFileName = artifactId + "-" + version + ".jar";
        String jarUrl = String.format("%s/%s/%s/%s/%s",
                baseUrl, groupPath, artifactId, version, jarFileName);
        
        Path jarPath = cacheDir.resolve(jarFileName);
        try {
            downloadFile(jarUrl, jarPath.toFile());
            jars.add(jarPath.toString());
        } catch (Exception e) {
            // Silent fail for missing dependencies - main JAR already available
            return jars;
        }
        
        // Download and parse POM for dependencies (only if depth < 3)
        if (depth < 3) {
            List<Dependency> dependencies = new ArrayList<>();

            // Add critical AWS SDK dependencies even if POM parsing fails
            if (groupId.equals("software.amazon.awssdk")) {
                addIfMissing(dependencies, "software.amazon.awssdk", "regions", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "awscore", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "protocol-core", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "http-client-spi", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "auth", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "json-utils", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "utils", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "sdk-core", version);
                addIfMissing(dependencies, "software.amazon.awssdk", "arrowhead-query-protocol", version);
                addIfMissing(dependencies, "org.reactivestreams", "reactive-streams", "1.0.4");
                if (artifactId.equals("crt-core") || artifactId.contains("crt")) {
                    addIfMissing(dependencies, "software.amazon.awssdk.crt", "aws-crt", "0.38.3");
                }
                if (artifactId.equals("http-auth-aws") || artifactId.contains("s3")) {
                    addIfMissing(dependencies, "software.amazon.eventstream", "eventstream", "1.0.1");
                    addIfMissing(dependencies, "software.amazon.awssdk", "http-auth-aws", version);
                    addIfMissing(dependencies, "software.amazon.awssdk", "netty-nio-client", version);
                    addIfMissing(dependencies, "software.amazon.awssdk", "apache-client", version);
                }
            }

            // Download and parse POM for dependencies (only if depth < 3)
            if (depth < 3) {
                try {
                    String pomFileName = artifactId + "-" + version + ".pom";
                    String pomUrl = String.format("%s/%s/%s/%s/%s",
                            baseUrl, groupPath, artifactId, version, pomFileName);
                    
                    Path pomPath = cacheDir.resolve(pomFileName);
                    downloadFile(pomUrl, pomPath.toFile());
                    
                    // Parse dependencies from POM
                    List<Dependency> parsedDeps = parsePomFileDeps(pomPath.toFile());
                    for (Dependency dep : parsedDeps) {
                        // Only add if not already present and has valid version
                        if (dep.version != null && !dep.version.startsWith("$")) {
                            boolean exists = false;
                            for (Dependency existing : dependencies) {
                                if (existing.groupId.equals(dep.groupId) && existing.artifactId.equals(dep.artifactId)) {
                                    exists = true;
                                    break;
                                }
                            }
                            if (!exists) {
                                dependencies.add(dep);
                            }
                        }
                    }
                } catch (Exception e) {
                    // Silent fail for POM parsing - we have fallback deps
                }
            }

            // Download runtime dependencies
            for (Dependency dep : dependencies) {
                if ("compile".equals(dep.scope) || "runtime".equals(dep.scope)) {
                    if (!dep.optional && dep.version != null && !dep.version.startsWith("$")) {
                        List<String> depJars = downloadArtifactWithDependencies(
                            dep.groupId, dep.artifactId, dep.version, 
                            baseUrl, cacheDir, visited, depth + 1);
                        jars.addAll(depJars);
                    } else if (dep.version == null || dep.version.startsWith("$")) {
                        System.err.println("WARNING: Skipping dependency with unresolved version: " + 
                            dep.groupId + ":" + dep.artifactId + ":" + dep.version);
                    }
                }
            }
        }
        
        return jars;
    }
    
    /**
     * Add dependency if not already in list.
     */
    private static void addIfMissing(List<Dependency> dependencies, String groupId, String artifactId, String version) {
        for (Dependency dep : dependencies) {
            if (dep.groupId.equals(groupId) && dep.artifactId.equals(artifactId)) {
                return; // Already exists
            }
        }
        Dependency newDep = new Dependency();
        newDep.groupId = groupId;
        newDep.artifactId = artifactId;
        newDep.version = version;
        newDep.scope = "compile";
        newDep.optional = false;
        dependencies.add(newDep);
    }
    
    /**
     * Simple dependency class.
     */
    private static class Dependency {
        String groupId;
        String artifactId;
        String version;
        String scope;
        boolean optional;
    }
    
    /**
     * Parse POM file and extract dependencies.
     */
    private static List<Dependency> parsePomFileDeps(File pomFile) throws Exception {
        List<Dependency> dependencies = new ArrayList<>();
        
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        DocumentBuilder builder = factory.newDocumentBuilder();
        Document doc = builder.parse(pomFile);
        doc.getDocumentElement().normalize();
        
        // First, extract properties for version resolution
        Map<String, String> properties = new HashMap<>();
        NodeList propertiesList = doc.getElementsByTagName("properties");
        if (propertiesList.getLength() > 0) {
            Element propertiesElement = (Element) propertiesList.item(0);
            NodeList propertyNodes = propertiesElement.getChildNodes();
            for (int i = 0; i < propertyNodes.getLength(); i++) {
                Node node = propertyNodes.item(i);
                if (node.getNodeType() == Node.ELEMENT_NODE) {
                    properties.put(node.getNodeName(), node.getTextContent().trim());
                }
            }
        }
        
        // Also check for version in parent or project
        NodeList versionList = doc.getElementsByTagName("version");
        if (versionList.getLength() > 0) {
            String projectVersion = versionList.item(0).getTextContent().trim();
            properties.put("project.version", projectVersion);
            properties.put("awsjavasdk.version", projectVersion);  // Common AWS SDK property
        }
        
        // Add hardcoded fallback versions for common properties not in POM
        properties.putIfAbsent("awscrt.version", "0.38.3");
        properties.putIfAbsent("reactive-streams.version", "1.0.4");
        properties.putIfAbsent("eventstream.version", "1.0.1");
        
        // Add hardcoded fallback versions for common properties not in POM
        properties.putIfAbsent("awscrt.version", "0.38.3");
        properties.putIfAbsent("reactive-streams.version", "1.0.4");
        properties.putIfAbsent("eventstream.version", "1.0.1");
        
        // Get dependencies element
        NodeList dependenciesList = doc.getElementsByTagName("dependencies");
        if (dependenciesList.getLength() == 0) {
            return dependencies;
        }
        
        Element dependenciesElement = (Element) dependenciesList.item(0);
        NodeList dependencyList = dependenciesElement.getElementsByTagName("dependency");
        
        for (int i = 0; i < dependencyList.getLength(); i++) {
            Node dependencyNode = dependencyList.item(i);
            if (dependencyNode.getNodeType() == Node.ELEMENT_NODE) {
                Element depElement = (Element) dependencyNode;
                
                Dependency dep = new Dependency();
                dep.groupId = getElementText(depElement, "groupId");
                dep.artifactId = getElementText(depElement, "artifactId");
                dep.version = getElementText(depElement, "version");
                dep.scope = getElementText(depElement, "scope", "compile");
                dep.optional = Boolean.parseBoolean(getElementText(depElement, "optional", "false"));
                
                // Resolve version properties
                if (dep.version != null && dep.version.startsWith("${") && dep.version.endsWith("}")) {
                    String propName = dep.version.substring(2, dep.version.length() - 1);
                    String resolvedVersion = properties.get(propName);
                    if (resolvedVersion != null) {
                        dep.version = resolvedVersion;
                    }
                }
                
                if (dep.groupId != null && dep.artifactId != null) {
                    dependencies.add(dep);
                }
            }
        }
        
        return dependencies;
    }

 /**
     * Download JAR from Maven repository.
     *
     * @param groupId    Maven group ID
     * @param artifactId Maven artifact ID
     * @param version    Maven version
     * @param baseUrl    Maven repository base URL
     * @return Path to downloaded JAR file
     */
    public static Object downloadJar(BString groupId, BString artifactId, BString version, BString baseUrl) {
        try {
            String group = groupId.getValue();
            String artifact = artifactId.getValue();
            String ver = version.getValue();
            String base = baseUrl.getValue();

            // Build Maven URL
            String groupPath = group.replace('.', '/');
            String jarFileName = artifact + "-" + ver + ".jar";
            String downloadUrl = String.format("%s/%s/%s/%s/%s",
                    base, groupPath, artifact, ver, jarFileName);

            // Create temp directory
            Path tempDir = Files.createTempDirectory("sdk-analyzer-");
            Path jarPath = tempDir.resolve(jarFileName);

            // Download JAR
            downloadFile(downloadUrl, jarPath.toFile());

            return StringUtils.fromString(jarPath.toString());

        } catch (Exception e) {
            return ErrorCreator.createError(
                    StringUtils.fromString("Failed to download JAR: " + e.getMessage()));
        }
    }

    /**
     * Download and parse POM file to extract dependencies.
     *
     * @param groupId    Maven group ID
     * @param artifactId Maven artifact ID
     * @param version    Maven version
     * @param baseUrl    Maven repository base URL
     * @return BArray of dependency maps
     */
    public static Object parsePom(BString groupId, BString artifactId, BString version, BString baseUrl) {
        try {
            String group = groupId.getValue();
            String artifact = artifactId.getValue();
            String ver = version.getValue();
            String base = baseUrl.getValue();

            // Build POM URL
            String groupPath = group.replace('.', '/');
            String pomFileName = artifact + "-" + ver + ".pom";
            String downloadUrl = String.format("%s/%s/%s/%s/%s",
                    base, groupPath, artifact, ver, pomFileName);

            // Download POM to temp file
            Path tempPom = Files.createTempFile("pom-", ".xml");
            downloadFile(downloadUrl, tempPom.toFile());

            // Parse POM
            List<BMap<BString, Object>> dependencies = parsePomFile(tempPom.toFile());

            // Clean up temp file
            Files.deleteIfExists(tempPom);

            // Convert to BArray
            MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
            ArrayType arrayType = TypeCreator.createArrayType(mapType);
            return ValueCreator.createArrayValue(dependencies.toArray(BMap[]::new), arrayType);

        } catch (Exception e) {
            // Return empty array if POM not found (not critical)
            return ErrorCreator.createError(
                    StringUtils.fromString("Failed to parse POM: " + e.getMessage()));
        }
    }

    /**
     * Download file from URL.
     *
     * @param urlStr URL to download from
     * @param file   File to save to
     * @throws Exception if download fails
     */
    private static void downloadFile(String urlStr, File file) throws Exception {
        URL url = java.net.URI.create(urlStr).toURL();
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setConnectTimeout(TIMEOUT);
        connection.setReadTimeout(TIMEOUT);
        connection.setRequestProperty("User-Agent", "Ballerina-SDK-Analyzer/1.0");

        int responseCode = connection.getResponseCode();
        if (responseCode != HttpURLConnection.HTTP_OK) {
            throw new Exception("HTTP error code: " + responseCode + " for URL: " + urlStr);
        }

        try (InputStream in = new BufferedInputStream(connection.getInputStream());
                FileOutputStream out = new FileOutputStream(file)) {

            byte[] buffer = new byte[BUFFER_SIZE];
            int bytesRead;
            while ((bytesRead = in.read(buffer)) != -1) {
                out.write(buffer, 0, bytesRead);
            }
        }
    }

    /**
     * Parse POM file and extract dependencies.
     *
     * @param pomFile POM file to parse
     * @return List of dependency maps
     * @throws Exception if parsing fails
     */
    private static List<BMap<BString, Object>> parsePomFile(File pomFile) throws Exception {
        List<BMap<BString, Object>> dependencies = new ArrayList<>();

        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        DocumentBuilder builder = factory.newDocumentBuilder();
        Document doc = builder.parse(pomFile);
        doc.getDocumentElement().normalize();

        // Get dependencies element
        NodeList dependenciesList = doc.getElementsByTagName("dependencies");
        if (dependenciesList.getLength() == 0) {
            return dependencies;
        }

        Element dependenciesElement = (Element) dependenciesList.item(0);
        NodeList dependencyList = dependenciesElement.getElementsByTagName("dependency");

        for (int i = 0; i < dependencyList.getLength(); i++) {
            Node dependencyNode = dependencyList.item(i);
            if (dependencyNode.getNodeType() == Node.ELEMENT_NODE) {
                Element dependency = (Element) dependencyNode;

                String groupId = getElementText(dependency, "groupId");
                String artifactId = getElementText(dependency, "artifactId");
                String version = getElementText(dependency, "version");
                String scope = getElementText(dependency, "scope", "compile");
                boolean optional = Boolean.parseBoolean(getElementText(dependency, "optional", "false"));

                if (groupId != null && artifactId != null && version != null) {
                    MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
                    BMap<BString, Object> depMap = ValueCreator.createMapValue(mapType);

                    depMap.put(StringUtils.fromString("groupId"), StringUtils.fromString(groupId));
                    depMap.put(StringUtils.fromString("artifactId"), StringUtils.fromString(artifactId));
                    depMap.put(StringUtils.fromString("version"), StringUtils.fromString(version));
                    depMap.put(StringUtils.fromString("scope"), StringUtils.fromString(scope));
                    depMap.put(StringUtils.fromString("optional"), optional);

                    dependencies.add(depMap);
                }
            }
        }

        return dependencies;
    }

    /**
     * Get text content of an XML element.
     *
     * @param parent  Parent element
     * @param tagName Tag name to find
     * @return Text content or null
     */
    private static String getElementText(Element parent, String tagName) {
        return getElementText(parent, tagName, null);
    }

    /**
     * Get text content of an XML element with default value.
     *
     * @param parent       Parent element
     * @param tagName      Tag name to find
     * @param defaultValue Default value if element not found
     * @return Text content or default value
     */
    private static String getElementText(Element parent, String tagName, String defaultValue) {
        NodeList nodeList = parent.getElementsByTagName(tagName);
        if (nodeList.getLength() > 0) {
            Node node = nodeList.item(0);
            return node.getTextContent().trim();
        }
        return defaultValue;
    }

    /**
     * Dynamically search Maven Central for an artifact containing the given class
     * and download it along with its dependencies. Used for runtime resolution of missing classes.
     *
     * @param fullyQualifiedClassName The fully qualified class name (e.g., "software.amazon.awssdk.awscore.AwsClient")
     * @param cacheDir Directory to download artifacts to
     * @return List of downloaded JAR paths (may be empty if search fails)
     */
    public static List<String> searchAndDownloadMissingClass(String fullyQualifiedClassName, Path cacheDir) {
        List<String> jars = new ArrayList<>();
        try {
            // URL-encode the class name for Maven Central search
            String encodedClass = java.net.URLEncoder.encode("\"" + fullyQualifiedClassName + "\"", "UTF-8");
            String searchUrl = String.format("https://search.maven.org/solrsearch/select?q=fc:%s&rows=5&wt=json",
                    encodedClass);

            var url = new URL(searchUrl);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(TIMEOUT);
            conn.setReadTimeout(TIMEOUT);
            conn.setRequestProperty("User-Agent", "Ballerina-SDK-Analyzer/1.0");

            int responseCode = conn.getResponseCode();
            if (responseCode != HttpURLConnection.HTTP_OK) {
                return jars;
            }

            try (InputStream in = new BufferedInputStream(conn.getInputStream())) {
                byte[] data = new byte[8192];
                StringBuilder response = new StringBuilder();
                int bytesRead;
                while ((bytesRead = in.read(data)) != -1) {
                    response.append(new String(data, 0, bytesRead, java.nio.charset.StandardCharsets.UTF_8));
                }

                String body = response.toString();

                // Parse simple JSON to extract first matching artifact
                int docStart = body.indexOf("\"docs\":[");
                if (docStart == -1) return jars;

                // Find first g (groupId), a (artifactId), v (version)
                int gStart = body.indexOf("\"g\":\"", docStart);
                int aStart = body.indexOf("\"a\":\"", docStart);
                int vStart = body.indexOf("\"v\":\"", docStart);

                if (gStart == -1 || aStart == -1 || vStart == -1) {
                    return jars;
                }

                String groupId = extractJsonValue(body, gStart + 5);
                String artifactId = extractJsonValue(body, aStart + 5);
                String version = extractJsonValue(body, vStart + 5);

                if (groupId != null && artifactId != null && version != null) {
                    System.err.println("INFO: Found artifact in Maven Central: " + groupId + ":" + artifactId + ":" + version);
                    
                    // Download the artifact and its dependencies
                    List<String> downloaded = downloadArtifactWithDependencies(
                            groupId, artifactId, version, DEFAULT_MAVEN_CENTRAL, cacheDir, new HashSet<>(), 0);
                    jars.addAll(downloaded);
                }
            }
        } catch (Exception e) {
            // Silent fail - best effort
        }

        return jars;
    }

    /**
     * Extract a JSON string value from a position in the response body.
     *
     * @param body The JSON response body
     * @param startPos Position after the opening quote
     * @return The extracted string value or null
     */
    private static String extractJsonValue(String body, int startPos) {
        try {
            int endPos = body.indexOf("\"", startPos);
            if (endPos == -1) return null;
            return body.substring(startPos, endPos);
        } catch (Exception e) {
            return null;
        }
    }
}
