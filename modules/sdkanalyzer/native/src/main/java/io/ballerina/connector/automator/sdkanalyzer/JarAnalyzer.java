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

import java.io.File;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Parameter;
import java.lang.reflect.Type;
import java.lang.reflect.TypeVariable;
import java.net.MalformedURLException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.MapType;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BString;

/**
 * Native Java class to analyze JAR files using reflection.
 * Extracts class metadata including methods, fields, constructors, and javadoc.
 */
public class JarAnalyzer {

    // Optional javadoc index: classFQN -> (memberName -> description)
    private static Map<String, Map<String, String>> javadocIndex = null;

    /**
     * Parse JAR file and extract all class information.
     * Can accept either a single JAR path or a result from Maven resolution.
     *
     * @param jarPathOrResult Path to JAR file or BMap from Maven resolution
     * @return BArray of class information maps
     */
    @SuppressWarnings("unchecked")
    public static Object parseJar(Object jarPathOrResult) {
        try {
            List<URL> urls = new ArrayList<>();
            Set<String> addedJars = new HashSet<>();
            String mainJarPath;
            
            // Check if input is a Maven resolution result (BMap) or simple string path
            if (jarPathOrResult instanceof BMap) {
                BMap<BString, Object> mavenResult = (BMap<BString, Object>) jarPathOrResult;
                
                // Get all JARs from Maven resolution
                Object allJarsObj = mavenResult.get(StringUtils.fromString("allJars"));
                if (allJarsObj instanceof io.ballerina.runtime.api.values.BArray allJars) {
                    
                    System.err.println("INFO: Loading " + allJars.getLength() + " JAR(s) from Maven resolution");
                    
                    for (int i = 0; i < allJars.getLength(); i++) {
                        String jarPath = allJars.getBString(i).getValue();
                        addJarPathIfExists(jarPath, urls, addedJars);
                    }
                }
                
                mainJarPath = mavenResult.get(StringUtils.fromString("mainJar")).toString();
            } else {
                // Simple string path (backward compatibility)
                String jarPath = jarPathOrResult.toString();
                File jarFile = new File(jarPath);
                
                if (!jarFile.exists()) {
                    return ErrorCreator.createError(
                        StringUtils.fromString("JAR file not found: " + jarPath));
                }
                
                mainJarPath = jarPath;
                addJarPathIfExists(jarPath, urls, addedJars);
                
                // Auto-discover dependency JARs in the same directory
                File parentDir = jarFile.getParentFile();
                if (parentDir != null && parentDir.exists()) {
                    File[] siblingJars = parentDir.listFiles((dir, name) -> 
                        name.endsWith(".jar") && !name.equals(jarFile.getName()));
                    if (siblingJars != null) {
                        for (File depJar : siblingJars) {
                            if (addJarPathIfExists(depJar.getPath(), urls, addedJars)) {
                                System.err.println("INFO: Adding dependency JAR to classpath: " + depJar.getName());
                            }
                        }
                    }
                }

                // Attempt to resolve dependencies from embedded Maven metadata
                String coordinate = extractMavenCoordinate(jarFile);
                if (coordinate != null) {
                    System.err.println("INFO: Resolving dependencies from embedded Maven coordinate: " + coordinate);
                    Object resolved = MavenResolver.resolveMavenArtifact(StringUtils.fromString(coordinate));
                    if (resolved instanceof BMap) {
                        addResolvedMavenJars((BMap<BString, Object>) resolved, urls, addedJars);
                    } else if (resolved instanceof BError) {
                        System.err.println("WARNING: Failed to resolve Maven dependencies: " + resolved);
                    }
                }
            }
            
            if (urls.isEmpty()) {
                return ErrorCreator.createError(
                    StringUtils.fromString("No JARs to analyze"));
            }
            
            List<BMap<BString, Object>> classes = new ArrayList<>();
            File mainJar = new File(mainJarPath);
            
            // Track failed classes for retry after dynamic resolution
            Set<String> failedClasses = new HashSet<>();
            Path cacheDir = null;

            try (URLClassLoader classLoader = new URLClassLoader(
                    urls.toArray(URL[]::new),
                    JarAnalyzer.class.getClassLoader());
                 JarFile jar = new JarFile(mainJar)) {

                // Attempt to find a javadoc JAR in the same directory as the main JAR
                try {
                    File parent = mainJar.getParentFile();
                    if (parent != null && parent.exists()) {
                        File[] candidates = parent.listFiles((dir, name) -> name.toLowerCase().contains("javadoc") && name.endsWith(".jar"));
                        if (candidates != null && candidates.length > 0) {
                            // Choose first candidate
                            File javadocJar = candidates[0];
                            System.err.println("INFO: Found javadoc jar: " + javadocJar.getName());
                            javadocIndex = JavadocExtractor.loadFromJar(javadocJar);
                            System.err.println("INFO: Loaded javadoc entries for " + javadocIndex.size() + " classes");
                        }
                    }
                } catch (Exception ignored) {
                }

                Enumeration<JarEntry> entries = jar.entries();

                while (entries.hasMoreElements()) {
                    JarEntry entry = entries.nextElement();
                    String entryName = entry.getName();

                    // Process only .class files
                    if (entryName.endsWith(".class") && !entryName.contains("$")) {
                        // Convert path to class name
                        String className = entryName
                                .replace('/', '.')
                                .substring(0, entryName.length() - 6);

                        try {
                            Class<?> clazz = classLoader.loadClass(className);

                            // Only process public classes
                            if (Modifier.isPublic(clazz.getModifiers())) {
                                BMap<BString, Object> classInfo = analyzeClass(clazz);
                                classes.add(classInfo);
                            }
                        } catch (NoClassDefFoundError e) {
                            // Track missing dependency for potential dynamic resolution
                            if (className.endsWith("Client") || className.endsWith("AsyncClient")) {
                                failedClasses.add(className);
                            }
                        } catch (ClassNotFoundException e) {
                            // Track for retry
                            if (className.endsWith("Client") || className.endsWith("AsyncClient")) {
                                failedClasses.add(className);
                            }
                        } catch (LinkageError | Exception e) {
                            // Track linkage errors
                            if (className.endsWith("Client") || className.endsWith("AsyncClient")) {
                                failedClasses.add(className);
                            }
                        }
                        // Track other exceptions
                        
                    }
                }
            }
            
            // Attempt to resolve and download missing dependencies
            if (!failedClasses.isEmpty() && cacheDir == null) {
                cacheDir = java.nio.file.Files.createTempDirectory("sdk-analyzer-missing-");
                
                for (String failedClass : failedClasses) {
                    // Extract the package to infer missing artifact
                    String pkg = failedClass.substring(0, failedClass.lastIndexOf('.'));
                    
                    // For AWS SDK classes, attempt to resolve the missing artifact
                    if (pkg.startsWith("software.amazon")) {
                        List<String> resolvedJars = MavenResolver.searchAndDownloadMissingClass(failedClass, cacheDir);
                        
                        if (!resolvedJars.isEmpty()) {
                            System.err.println("INFO: Downloaded missing dependency for " + failedClass);
                            
                            // Add newly downloaded JARs to urls and retry (would need classloader recreation)
                            for (String jarPath : resolvedJars) {
                                File jarFile = new File(jarPath);
                                if (jarFile.exists()) {
                                    try {
                                        urls.add(jarFile.toURI().toURL());
                                    } catch (MalformedURLException ignored) {}
                                }
                            }
                        }
                    }
                }
            }

            // Convert to BArray
            MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
            return ValueCreator.createArrayValue(classes.toArray(BMap[]::new),
                TypeCreator.createArrayType(mapType));

        } catch (Exception e) {
            return ErrorCreator.createError(
                StringUtils.fromString("Failed to parse JAR: " + e.getMessage()));
        }
    }

    // Overload to accept Ballerina BString directly from Ballerina Java interop
    public static Object parseJar(io.ballerina.runtime.api.values.BString jarPath) {
        if (jarPath == null) {
            return null;
        }
        return parseJar(jarPath.getValue());
    }

    private static boolean addJarPathIfExists(String jarPath, List<URL> urls, Set<String> addedJars) throws Exception {
        File jarFile = new File(jarPath);
        if (jarFile.exists()) {
            String canonicalPath = jarFile.getCanonicalPath();
            if (addedJars.add(canonicalPath)) {
                urls.add(jarFile.toURI().toURL());
                return true;
            }
        }
        return false;
    }

    private static void addResolvedMavenJars(BMap<BString, Object> mavenResult,
                                             List<URL> urls, Set<String> addedJars) throws Exception {
        Object allJarsObj = mavenResult.get(StringUtils.fromString("allJars"));
        if (allJarsObj instanceof io.ballerina.runtime.api.values.BArray allJars) {
            System.err.println("INFO: Adding " + allJars.getLength() + " resolved JAR(s) to classpath");
            for (int i = 0; i < allJars.getLength(); i++) {
                String jarPath = allJars.getBString(i).getValue();
                addJarPathIfExists(jarPath, urls, addedJars);
            }
        }
    }

    private static String extractMavenCoordinate(File jarFile) {
        try (JarFile jar = new JarFile(jarFile)) {
            Enumeration<JarEntry> entries = jar.entries();
            while (entries.hasMoreElements()) {
                JarEntry entry = entries.nextElement();
                String name = entry.getName();
                if (name.startsWith("META-INF/maven/") && name.endsWith("pom.properties")) {
                    Properties props = new Properties();
                    try (InputStream in = jar.getInputStream(entry)) {
                        props.load(in);
                    }
                    String groupId = props.getProperty("groupId");
                    String artifactId = props.getProperty("artifactId");
                    String version = props.getProperty("version");
                    if (groupId != null && artifactId != null && version != null) {
                        return groupId + ":" + artifactId + ":" + version;
                    }
                }
            }
        } catch (Exception e) {
            System.err.println("WARNING: Failed to read Maven metadata from JAR: " + e.getMessage());
        }
        return null;
    }

    /**
     * Analyze a single class using reflection.
     *
     * @param clazz The class to analyze
     * @return BMap containing class metadata
     */
    private static BMap<BString, Object> analyzeClass(Class<?> clazz) {
        MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
        BMap<BString, Object> classInfo = ValueCreator.createMapValue(mapType);

        // Basic class information
        classInfo.put(StringUtils.fromString("className"), StringUtils.fromString(clazz.getName()));
        classInfo.put(StringUtils.fromString("isInterface"), clazz.isInterface());
        classInfo.put(StringUtils.fromString("isAbstract"), Modifier.isAbstract(clazz.getModifiers()));
        classInfo.put(StringUtils.fromString("isEnum"), clazz.isEnum());

        // Superclass
        Class<?> superClass = clazz.getSuperclass();
        if (superClass != null && !superClass.equals(Object.class)) {
            classInfo.put(StringUtils.fromString("superClass"), StringUtils.fromString(superClass.getName()));
        } else {
            classInfo.put(StringUtils.fromString("superClass"), null);
        }

        // Interfaces
        Class<?>[] interfaces = clazz.getInterfaces();
        String[] interfaceNames = new String[interfaces.length];
        for (int i = 0; i < interfaces.length; i++) {
            interfaceNames[i] = interfaces[i].getName();
        }
        // Convert to BString[] for Ballerina runtime array creation
        BString[] interfaceNamesB = new BString[interfaceNames.length];
        for (int i = 0; i < interfaceNames.length; i++) {
            interfaceNamesB[i] = StringUtils.fromString(interfaceNames[i]);
        }
        classInfo.put(StringUtils.fromString("interfaces"),
                ValueCreator.createArrayValue(interfaceNamesB));

        // Annotations
        String[] annotations = extractAnnotations(clazz.getAnnotations());
        BString[] annotationsB = new BString[annotations.length];
        for (int i = 0; i < annotations.length; i++) {
            annotationsB[i] = StringUtils.fromString(annotations[i]);
        }
        classInfo.put(StringUtils.fromString("annotations"),
            ValueCreator.createArrayValue(annotationsB));

        // Check if deprecated
        classInfo.put(StringUtils.fromString("isDeprecated"),
                clazz.isAnnotationPresent(Deprecated.class));

        // // Javadoc - not available at runtime, set to null
        // classInfo.put(StringUtils.fromString("javadoc"), null);

        // Extract methods
        List<BMap<BString, Object>> methods = new ArrayList<>();
        for (Method method : clazz.getDeclaredMethods()) {
            if (Modifier.isPublic(method.getModifiers())) {
                methods.add(analyzeMethod(method));
            }
        }
        classInfo.put(StringUtils.fromString("methods"),
                ValueCreator.createArrayValue(methods.toArray(BMap[]::new), 
                TypeCreator.createArrayType(mapType)));

        // Extract fields
        List<BMap<BString, Object>> fields = new ArrayList<>();
        for (Field field : clazz.getDeclaredFields()) {
            if (Modifier.isPublic(field.getModifiers())) {
                fields.add(analyzeField(field));
            }
        }
        classInfo.put(StringUtils.fromString("fields"),
                ValueCreator.createArrayValue(fields.toArray(BMap[]::new), 
                TypeCreator.createArrayType(mapType)));

        // Extract constructors
        List<BMap<BString, Object>> constructors = new ArrayList<>();
        for (Constructor<?> constructor : clazz.getDeclaredConstructors()) {
            if (Modifier.isPublic(constructor.getModifiers())) {
                constructors.add(analyzeConstructor(constructor));
            }
        }
        classInfo.put(StringUtils.fromString("constructors"),
                ValueCreator.createArrayValue(constructors.toArray(BMap[]::new), 
                TypeCreator.createArrayType(mapType)));

        return classInfo;
    }

    /**
     * Analyze a method using reflection.
     *
     * @param method The method to analyze
     * @return BMap containing method metadata
     */
    private static BMap<BString, Object> analyzeMethod(Method method) {
        MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
        BMap<BString, Object> methodInfo = ValueCreator.createMapValue(mapType);

        methodInfo.put(StringUtils.fromString("name"), StringUtils.fromString(method.getName()));
        // Use getGenericReturnType to preserve generic type parameters (e.g., List<Tag> instead of just List)
        Type genericReturnType = method.getGenericReturnType();
        methodInfo.put(StringUtils.fromString("returnType"),
                StringUtils.fromString(genericReturnType.getTypeName()));
        methodInfo.put(StringUtils.fromString("isStatic"), Modifier.isStatic(method.getModifiers()));
        methodInfo.put(StringUtils.fromString("isFinal"), Modifier.isFinal(method.getModifiers()));
        methodInfo.put(StringUtils.fromString("isAbstract"), Modifier.isAbstract(method.getModifiers()));
        methodInfo.put(StringUtils.fromString("isDeprecated"),
                method.isAnnotationPresent(Deprecated.class));
        // Attach javadoc summary if available
        String methodJavadoc = null;
        try {
            if (javadocIndex != null) {
                Map<String, String> classMap = javadocIndex.get(method.getDeclaringClass().getName());
                if (classMap == null) {
                    // try simple dot form (some javadocs use dot names already)
                    classMap = javadocIndex.get(method.getDeclaringClass().getName().replace('$', '.'));
                }
                if (classMap != null) {
                    String desc = classMap.get(method.getName());
                    if (desc != null) methodJavadoc = desc;
                }
            }
        } catch (Exception ignored) {}
        methodInfo.put(StringUtils.fromString("javadoc"), methodJavadoc == null ? null : StringUtils.fromString(methodJavadoc));

        // Parameters
        Parameter[] parameters = method.getParameters();
        List<BMap<BString, Object>> paramList = new ArrayList<>();
        for (Parameter param : parameters) {
            paramList.add(analyzeParameter(param));
        }
        methodInfo.put(StringUtils.fromString("parameters"),
                ValueCreator.createArrayValue(paramList.toArray(BMap[]::new), 
                TypeCreator.createArrayType(mapType)));

        // Exceptions
        Class<?>[] exceptions = method.getExceptionTypes();
        String[] exceptionNames = new String[exceptions.length];
        for (int i = 0; i < exceptions.length; i++) {
            exceptionNames[i] = exceptions[i].getName();
        }
        BString[] exceptionNamesB = new BString[exceptionNames.length];
        for (int i = 0; i < exceptionNames.length; i++) {
            exceptionNamesB[i] = StringUtils.fromString(exceptionNames[i]);
        }
        methodInfo.put(StringUtils.fromString("exceptions"),
            ValueCreator.createArrayValue(exceptionNamesB));

        // Type parameters (generics)
        TypeVariable<Method>[] typeParams = method.getTypeParameters();
        String[] typeParamNames = new String[typeParams.length];
        for (int i = 0; i < typeParams.length; i++) {
            typeParamNames[i] = typeParams[i].getName();
        }
        BString[] typeParamNamesB = new BString[typeParamNames.length];
        for (int i = 0; i < typeParamNames.length; i++) {
            typeParamNamesB[i] = StringUtils.fromString(typeParamNames[i]);
        }
        methodInfo.put(StringUtils.fromString("typeParameters"),
            ValueCreator.createArrayValue(typeParamNamesB));

        return methodInfo;
    }

    /**
     * Analyze a method/constructor parameter.
     *
     * @param param The parameter to analyze
     * @return BMap containing parameter metadata
     */
    private static BMap<BString, Object> analyzeParameter(Parameter param) {
        MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
        BMap<BString, Object> paramInfo = ValueCreator.createMapValue(mapType);

        // Parameter name (may be arg0, arg1 if compiled without -parameters flag)
        String paramName = param.isNamePresent() ? param.getName() : "arg" + param.hashCode();
        paramInfo.put(StringUtils.fromString("name"), StringUtils.fromString(paramName));

        paramInfo.put(StringUtils.fromString("type"),
                StringUtils.fromString(param.getType().getName()));
        paramInfo.put(StringUtils.fromString("isVarArgs"), param.isVarArgs());

        // Extract generic type arguments if present
        Type paramType = param.getParameterizedType();
        String[] typeArgs = extractTypeArguments(paramType);
        BString[] typeArgsB = new BString[typeArgs.length];
        for (int i = 0; i < typeArgs.length; i++) {
            typeArgsB[i] = StringUtils.fromString(typeArgs[i]);
        }
        paramInfo.put(StringUtils.fromString("typeArguments"),
            ValueCreator.createArrayValue(typeArgsB));
        
        // If this is a Request class, extract its fields as parameters
        Class<?> paramClass = param.getType();
        if (paramClass.getSimpleName().endsWith("Request")) {
            try {
                List<BMap<BString, Object>> requestParams = new ArrayList<>();
                
                // Detect required fields in this Request class
                Set<String> requiredFieldNames = detectRequiredFields(paramClass);
                
                // Extract getter methods from Request class
                Method[] allMethods = paramClass.getDeclaredMethods();
                for (Method method : allMethods) {
                    String methodName = method.getName();
                    
                    // AWS SDK v2 uses simple method names, not get/is prefixed
                    // Skip internal methods and common object methods
                    if (methodName.equals("getClass") ||
                        methodName.equals("toString") ||
                        methodName.equals("hashCode") ||
                        methodName.equals("equals") ||
                        methodName.equals("getValueForField") ||
                        methodName.equals("sdkFields") ||
                        methodName.equals("serializableBuilderClass") ||
                        methodName.equals("toBuilder") ||
                        methodName.equals("equalsBySdkFields") ||
                        methodName.contains("lambda") ||
                        methodName.startsWith("access$") ||
                        methodName.equals("setter") ||
                        methodName.equals("getter") ||
                        !Modifier.isPublic(method.getModifiers()) ||
                        method.getParameterCount() != 0) {
                        continue;
                    }
                    
                    Class<?> returnType = method.getReturnType();
                    String returnTypeName = returnType.getSimpleName();
                    String fieldName = methodName;
                    
                    // Skip common SDK types that aren't actual parameters
                    if (returnTypeName.equals("Class") || 
                        returnTypeName.equals("CopyableBuilder") ||
                        returnTypeName.equals("Builder") ||
                        returnTypeName.contains("Builder")) {
                        continue;
                    }
                    
                    // Check if already added
                    boolean alreadyAdded = false;
                    for (BMap<BString, Object> p : requestParams) {
                        if (p.get(StringUtils.fromString("name")).toString().equals(fieldName)) {
                            alreadyAdded = true;
                            break;
                        }
                    }
                    
                    if (!alreadyAdded) {
                        BMap<BString, Object> field = ValueCreator.createMapValue(mapType);
                        field.put(StringUtils.fromString("name"), StringUtils.fromString(fieldName));
                        field.put(StringUtils.fromString("type"), StringUtils.fromString(returnTypeName));
                        
                        // Use getGenericReturnType to get full type including generics (e.g., java.util.List<software.amazon.awssdk.services.s3.model.Tag>)
                        Type genericReturnType = method.getGenericReturnType();
                        String fullTypeName = genericReturnType.getTypeName();
                        field.put(StringUtils.fromString("fullType"), StringUtils.fromString(fullTypeName));
                        
                        // Mark as required if detected, otherwise false
                        boolean isRequired = requiredFieldNames.contains(fieldName);
                        field.put(StringUtils.fromString("isRequired"), isRequired);
                        
                        // isCommonlyUsed will be set by LLM in next phase
                        field.put(StringUtils.fromString("isCommonlyUsed"), false);
                        
                        requestParams.add(field);
                    }
                }
                
                if (!requestParams.isEmpty()) {
                    paramInfo.put(StringUtils.fromString("requestFields"),
                        ValueCreator.createArrayValue(requestParams.toArray(BMap[]::new), 
                        TypeCreator.createArrayType(mapType)));
                }
            } catch (SecurityException e) {
                // Silently ignore if we can't extract request fields
            }
        }

        return paramInfo;
    }

    /**
     * Analyze a field using reflection.
     *
     * @param field The field to analyze
     * @return BMap containing field metadata
     */
    private static BMap<BString, Object> analyzeField(Field field) {
        MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
        BMap<BString, Object> fieldInfo = ValueCreator.createMapValue(mapType);

        fieldInfo.put(StringUtils.fromString("name"), StringUtils.fromString(field.getName()));
        fieldInfo.put(StringUtils.fromString("type"),
                StringUtils.fromString(field.getType().getName()));
        fieldInfo.put(StringUtils.fromString("isStatic"), Modifier.isStatic(field.getModifiers()));
        fieldInfo.put(StringUtils.fromString("isFinal"), Modifier.isFinal(field.getModifiers()));
        fieldInfo.put(StringUtils.fromString("isDeprecated"),
                field.isAnnotationPresent(Deprecated.class));
        String fieldJavadoc = null;
        try {
            if (javadocIndex != null) {
                Map<String, String> classMap = javadocIndex.get(field.getDeclaringClass().getName());
                if (classMap == null) {
                    classMap = javadocIndex.get(field.getDeclaringClass().getName().replace('$', '.'));
                }
                if (classMap != null) {
                    String desc = classMap.get(field.getName());
                    if (desc != null) fieldJavadoc = desc;
                }
            }
        } catch (Exception ignored) {}
        fieldInfo.put(StringUtils.fromString("javadoc"), fieldJavadoc == null ? null : StringUtils.fromString(fieldJavadoc));

        return fieldInfo;
    }

    /**
     * Analyze a constructor using reflection.
     *
     * @param constructor The constructor to analyze
     * @return BMap containing constructor metadata
     */
    private static BMap<BString, Object> analyzeConstructor(Constructor<?> constructor) {
        MapType mapType = TypeCreator.createMapType(PredefinedTypes.TYPE_JSON);
        BMap<BString, Object> constructorInfo = ValueCreator.createMapValue(mapType);

        constructorInfo.put(StringUtils.fromString("isDeprecated"),
                constructor.isAnnotationPresent(Deprecated.class));
        String ctorJavadoc = null;
        try {
            if (javadocIndex != null) {
                Map<String, String> classMap = javadocIndex.get(constructor.getDeclaringClass().getName());
                if (classMap == null) {
                    classMap = javadocIndex.get(constructor.getDeclaringClass().getName().replace('$', '.'));
                }
                // constructors typically don't have a simple member name in summary; look for "<init>" or class simple name
                if (classMap != null) {
                    String simple = constructor.getDeclaringClass().getSimpleName();
                    String desc = classMap.get(simple);
                    if (desc == null) desc = classMap.get("<init>");
                    if (desc != null) ctorJavadoc = desc;
                }
            }
        } catch (Exception ignored) {}
        constructorInfo.put(StringUtils.fromString("javadoc"), ctorJavadoc == null ? null : StringUtils.fromString(ctorJavadoc));

        // Parameters
        Parameter[] parameters = constructor.getParameters();
        List<BMap<BString, Object>> paramList = new ArrayList<>();
        for (Parameter param : parameters) {
            paramList.add(analyzeParameter(param));
        }
        constructorInfo.put(StringUtils.fromString("parameters"),
                ValueCreator.createArrayValue(paramList.toArray(BMap[]::new), 
                TypeCreator.createArrayType(mapType)));

        // Exceptions
        Class<?>[] exceptions = constructor.getExceptionTypes();
        String[] exceptionNames = new String[exceptions.length];
        for (int i = 0; i < exceptions.length; i++) {
            exceptionNames[i] = exceptions[i].getName();
        }
        BString[] exceptionNamesB = new BString[exceptionNames.length];
        for (int i = 0; i < exceptionNames.length; i++) {
            exceptionNamesB[i] = StringUtils.fromString(exceptionNames[i]);
        }
        constructorInfo.put(StringUtils.fromString("exceptions"),
                ValueCreator.createArrayValue(exceptionNamesB));

        return constructorInfo;
    }

    /**
     * Extract annotation names from annotations array.
     *
     * @param annotations Array of annotations
     * @return Array of annotation class names
     */
    private static String[] extractAnnotations(java.lang.annotation.Annotation[] annotations) {
        String[] names = new String[annotations.length];
        for (int i = 0; i < annotations.length; i++) {
            names[i] = annotations[i].annotationType().getName();
        }
        return names;
    }

    /**
     * Extract generic type arguments from a parameterized type.
     *
     * @param type The type to analyze
     * @return Array of type argument names
     */
    private static String[] extractTypeArguments(Type type) {
        if (type instanceof java.lang.reflect.ParameterizedType paramType) {
            Type[] typeArgs = paramType.getActualTypeArguments();
            String[] names = new String[typeArgs.length];
            for (int i = 0; i < typeArgs.length; i++) {
                names[i] = typeArgs[i].getTypeName();
            }
            return names;
        }
        return new String[0];
    }

    /**
     * Detect required fields in a Request class by analyzing:
     * 1. Constructor parameters (fields used in constructor are typically required)
     * 2. Fields with @NotNull annotation (universal requirement marker)
     */
    private static Set<String> detectRequiredFields(Class<?> requestClass) {
        Set<String> requiredFields = new HashSet<>();
        
        try {
            // Check annotations on fields/methods for @NotNull patterns
            // This is universal across different SDKs
            try {
                @SuppressWarnings("unchecked")
                Class<? extends java.lang.annotation.Annotation> notNullClass = 
                    (Class<? extends java.lang.annotation.Annotation>) 
                    Class.forName("javax.validation.constraints.NotNull");
                
                for (Method method : requestClass.getDeclaredMethods()) {
                    if (method.isAnnotationPresent(notNullClass)) {
                        String methodName = method.getName();
                        if (methodName.length() > 0 && !methodName.startsWith("get") && 
                            !methodName.startsWith("is") && !methodName.startsWith("set")) {
                            requiredFields.add(methodName);
                        }
                    }
                }
            } catch (ClassNotFoundException e) {
                // @NotNull annotation not available in classpath, skip
            }
            
        } catch (SecurityException e) {
            // If we can't detect required fields, use empty set (all optional)
        }
        
        return requiredFields;
    }
}
