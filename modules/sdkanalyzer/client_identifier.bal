// Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/io;
import ballerina/os;
import ballerina/regex;

# Use Anthropic LLM to find root client class using weighted scoring
#
# + classes - All classes from SDK
# + maxCandidates - Maximum number of candidates to consider
# + roleHint - Optional target role hint (admin/producer/consumer)
# + return - Sorted candidates with LLM scores
public function identifyClientClassWithLLM(ClassInfo[] classes, int maxCandidates, string? roleHint = ())
        returns [ClassInfo, LLMClientScore][]|AnalyzerError {

    if !isAnthropicConfigured() {
        return error AnalyzerError("Anthropic LLM not configured: LLM-only candidate scoring required");
    }

    // Filter potential candidates using conservative structural rules
    ClassInfo[] potential = [];
    foreach ClassInfo cls in classes {
        if shouldConsiderAsClientCandidate(cls) {
            potential.push(cls);
        }
    }
    if potential.length() > 0 {
        ClassInfo[] prioritized = from ClassInfo c in potential
            order by quickClientCandidatePriority(c) descending
            select c;

        int candidateLimit = maxCandidates * 2;
        if candidateLimit < 12 {
            candidateLimit = 12;
        }
        if candidateLimit > 30 {
            candidateLimit = 30;
        }

        if prioritized.length() > candidateLimit {
            potential = prioritized.slice(0, candidateLimit);
        } else {
            potential = prioritized;
        }
    }

    if potential.length() == 0 {
        // Structural filtering produced no candidates.
        // Fall back to a looser selection.
        ClassInfo[] fallback = [];
        foreach ClassInfo cls in classes {
            if !cls.className.includes("$") && !cls.isEnum && !cls.isAbstract && cls.methods.length() > 0 {
                fallback.push(cls);
            }
        }
        if fallback.length() == 0 {
            return error AnalyzerError("No potential client candidates after structural filtering");
        }
        // Sort fallback by method count descending and take a reasonable sample
        ClassInfo[] sortedFallback = from var c in fallback
            order by c.methods.length() descending
            select c;
        int sampleCount = sortedFallback.length() > 10 ? 10 : sortedFallback.length();
        potential = sortedFallback.slice(0, sampleCount);
    }

    [ClassInfo, LLMClientScore][] scored = [];

    // Score each potential candidate using the LLM exclusively. Propagate or log failures per-class.
    foreach ClassInfo cls in potential {
        LLMClientScore|error score = calculateLLMClientScore(cls, classes, roleHint);
        if score is LLMClientScore {
            scored.push([cls, score]);
        } else {
            error e = <error>score;
            io:println(string `LLM scoring failed for ${cls.className}: ${e.message()}`);
        }
    }

    if scored.length() == 0 {
        return error AnalyzerError("LLM failed to score any client candidates");
    }

    // Sort by LLM total score descending
    [ClassInfo, LLMClientScore][] sorted = from var [cls, score] in scored
        order by score.totalScore descending
        select [cls, score];

    int finalCount = sorted.length() < maxCandidates ? sorted.length() : maxCandidates;
    return sorted.slice(0, finalCount);
}

public function detectClientInitPatternWithLLM(
        ClassInfo rootClient,
        ClassInfo[] allClasses,
        string[] dependencyJarPaths
) returns ClientInitPattern|error {
    if !isAnthropicConfigured() {
        return error("Anthropic LLM not configured: cannot detect init pattern using LLM");
    }

    ClientInitPattern|error patternResult = detectInitPatternWithLLM(rootClient, allClasses, dependencyJarPaths);
    if patternResult is error {
        return patternResult;
    }
    ClientInitPattern pattern = patternResult;

    if pattern.patternName == "builder" || pattern.patternName == "static-factory" ||
        pattern.patternName == "constructor" {
        [string?, ConnectionFieldInfo[], SyntheticTypeMetadata[]] builderResult =
            resolveBuilderConnectionFields(
                rootClient, allClasses, dependencyJarPaths,
                rootClient.packageName, rootClient.simpleName
            );
        pattern.builderClass = builderResult[0];
        pattern.connectionFields = builderResult[1];
        pattern.syntheticTypeMetadata = builderResult[2];
    }

    return pattern;
}

# Extract all public methods from root client class
#
# + rootClient - The root client class
# + return - All public methods with metadata
public function extractPublicMethods(ClassInfo rootClient) returns MethodInfo[] {
    MethodInfo[] publicMethods = [];

    foreach MethodInfo method in rootClient.methods {
        // Skip constructor methods and private methods
        if !method.name.startsWith("<") && method.name != "toString" &&
            method.name != "hashCode" && method.name != "equals" {
            string methodNameLower = method.name.toLowerAscii();
            if methodNameLower.endsWith("paginator") {
                continue;
            }
            publicMethods.push(method);
        }
    }

    return publicMethods;
}

# Use LLM to rank methods by usage frequency  
#
# + methods - All public methods from root client
# + return - Methods ranked by usage frequency (limited to 40 if more)
public function rankMethodsByUsageWithLLM(MethodInfo[] methods) returns MethodInfo[]|error {

    // If 40 or fewer methods, return all without LLM ranking
    if methods.length() <= 40 {
        return methods;
    }

    // If more than 40 methods, use LLM to rank and extract top 40
    if !isAnthropicConfigured() {
        return error("Anthropic LLM not configured: cannot rank methods using LLM");
    }

    // Use LLM to rank methods by usage frequency and return top 40
    return rankMethodsUsingLLM(methods);
}

# Extract request/response parameters and corresponding fields with types
#
# + methods - Methods to analyze for parameters
# + allClasses - All classes for type lookup
# + return - Enhanced methods with parameter field information
public function extractParameterFieldTypes(MethodInfo[] methods, ClassInfo[] allClasses)
        returns MethodInfo[] {

    // Deduplicate overloads preferring variants that resolve to a Request class
    map<MethodInfo> chosen = {};
    foreach MethodInfo method in methods {
        boolean hasRequestParam = false;
        foreach ParameterInfo p in method.parameters {
            ClassInfo? resolved = resolveRequestClassFromParameter(p, allClasses, method.name);
            if resolved is ClassInfo {
                hasRequestParam = true;
                break;
            }
        }

        if !chosen.hasKey(method.name) {
            chosen[method.name] = method;
        } else {
            MethodInfo? existing = chosen[method.name];
            if existing is MethodInfo {
                boolean existingHasRequest = false;
                foreach ParameterInfo p in existing.parameters {
                    ClassInfo? r = resolveRequestClassFromParameter(p, allClasses, existing.name);
                    if r is ClassInfo {
                        existingHasRequest = true;
                        break;
                    }
                }
                if !existingHasRequest && hasRequestParam {
                    chosen[method.name] = method;
                } else if existingHasRequest && hasRequestParam {
                    boolean existingDirect = false;
                    boolean currentDirect = false;
                    foreach ParameterInfo p in existing.parameters {
                        if p.typeName != "" && (p.typeName.endsWith("Request") || p.typeName.indexOf("Request") != -1) {
                            existingDirect = true;
                            break;
                        }
                    }
                    foreach ParameterInfo p in method.parameters {
                        if p.typeName != "" && (p.typeName.endsWith("Request") || p.typeName.indexOf("Request") != -1) {
                            currentDirect = true;
                            break;
                        }
                    }
                    if currentDirect && !existingDirect {
                        chosen[method.name] = method;
                    }
                }
            }
        }
    }

    // Reconstruct ordered list preserving first-seen order of original methods
    MethodInfo[] enhancedMethodsOrdered = [];
    map<boolean> added = {};
    foreach MethodInfo m in methods {
        if !added.hasKey(m.name) {
            MethodInfo? selOpt = chosen[m.name];
            if selOpt is MethodInfo {
                MethodInfo sel = selOpt;
                MethodInfo enhancedMethod = {
                    name: sel.name,
                    returnType: sel.returnType,
                    parameters: extractEnhancedParameters(sel.parameters, allClasses, sel.name),
                    isStatic: sel.isStatic,
                    isFinal: sel.isFinal,
                    isAbstract: sel.isAbstract,
                    isDeprecated: sel.isDeprecated,
                    annotations: sel.annotations,
                    exceptions: sel.exceptions,
                    typeParameters: sel.typeParameters,
                    signature: sel.signature
                };
                enhancedMethodsOrdered.push(enhancedMethod);
                added[m.name] = true;
            }
        }
    }

    return enhancedMethodsOrdered;
}

# Generate structured metadata with all information
#
# + rootClient - The identified root client
# + initPattern - The initialization pattern
# + rankedMethods - Methods ranked by usage
# + allClasses - All classes for context
# + dependencyJarPaths - Dependency JAR paths for resolving external type references
# + config - Analyzer configuration
# + return - Complete structured metadata
public function generateStructuredMetadata(
        ClassInfo rootClient,
        ClientInitPattern initPattern,
        MethodInfo[] rankedMethods,
        ClassInfo[] allClasses,
        string[] dependencyJarPaths,
        AnalyzerConfig config
) returns StructuredSDKMetadata {

    // Track enums globally to avoid duplication
    map<EnumMetadata> enumCache = {};

    // Track member classes referenced in List/Map types
    map<ClassInfo> memberClassCache = {};

    // Step 1: Collect all parameter instances (method::param) and their fields
    map<RequestFieldInfo[]> paramInstanceFieldsMap = {};

    foreach MethodInfo method in rankedMethods {
        foreach ParameterInfo param in method.parameters {
            ClassInfo? requestClass = resolveRequestClassFromParameter(param, allClasses, method.name);
            if requestClass is ClassInfo {
                string instanceKey = string `${method.name}::${param.name}`;
                // Extract fields for this parameter instance (no deduplication to respect per-parameter context)
                RequestFieldInfo[] fields = extractRequestFields(requestClass);
                paramInstanceFieldsMap[instanceKey] = fields;
            }
        }
    }

    // Step 2: Batch analyze all parameter instances with LLM
    map<string[]> requiredFieldsMap = {};

    if !config.disableLLM && paramInstanceFieldsMap.length() > 0 {
        string batchPrompt = "";
        foreach [string, RequestFieldInfo[]] [instanceKey, fields] in paramInstanceFieldsMap.entries() {
            if batchPrompt.length() > 0 {
                batchPrompt += "\n\n";
            }
            batchPrompt += string `${instanceKey}:\n`;
            foreach RequestFieldInfo fld in fields {
                batchPrompt += string `  - ${fld.name}\n`;
            }
        }

        AnthropicConfiguration|error llmConfigResult = getAnthropicConfig();
        if llmConfigResult is AnthropicConfiguration {
            string sysPrompt = "You are an expert Java SDK analyzer. Based on your knowledge of SDK design patterns, " +
                "identify which fields are REQUIRED for each parameter instance. " +
                "Return ONLY valid JSON: {\"Method::ParamName\":[\"requiredField1\",\"requiredField2\"]}";

            string userPrompt = string `Identify REQUIRED fields for these method parameters:\n\n${batchPrompt}\n\nReturn JSON: {"Method::ParamName":["field1","field2"]}`;

            json|error llmResponse = callAnthropicAPI(llmConfigResult, sysPrompt, userPrompt);

            if !(llmResponse is error) {
                string responseText = extractResponseText(llmResponse);
                string jsonText = responseText.trim();

                // Extract JSON from markdown code blocks or find JSON object
                int? jsonStartIdx = jsonText.indexOf("```json");
                if jsonStartIdx is int {
                    jsonText = jsonText.substring(jsonStartIdx + 7);
                }
                int? codeBlockIdx = jsonText.indexOf("```");
                if codeBlockIdx is int {
                    jsonText = jsonText.substring(0, codeBlockIdx);
                }

                // Find the first { and last }
                int? firstBrace = jsonText.indexOf("{");
                int? lastBrace = jsonText.lastIndexOf("}");
                if firstBrace is int && lastBrace is int && lastBrace > firstBrace {
                    jsonText = jsonText.substring(firstBrace, lastBrace + 1);
                }

                jsonText = jsonText.trim();

                json|error parsedJson = jsonText.fromJsonString();
                if parsedJson is map<json> {
                    foreach [string, json] [instanceKey, fieldData] in parsedJson.entries() {
                        if fieldData is json[] {
                            string[] reqFields = [];
                            foreach json item in fieldData {
                                if item is string {
                                    reqFields.push(item);
                                }
                            }
                            requiredFieldsMap[instanceKey] = reqFields;
                        }
                    }
                }
            }
        }
    }

    // Step 3: Populate request fields using cached results
    MethodInfo[] methodsWithRequestFields = [];
    foreach int methodIdx in 0 ..< rankedMethods.length() {
        MethodInfo method = rankedMethods[methodIdx];
        MethodInfo updatedMethod = method;

        // Update each parameter with request fields if it's a request object
        ParameterInfo[] updatedParams = [];
        foreach int paramIdx in 0 ..< method.parameters.length() {
            ParameterInfo param = method.parameters[paramIdx];
            ParameterInfo updatedParam = param;

            // Try to resolve the request class via generics, builders, or method-name heuristics
            ClassInfo? requestClass = resolveRequestClassFromParameter(param, allClasses, method.name);
            if requestClass is ClassInfo {
                // Replace the parameter's exposed type with the resolved Request class
                updatedParam.typeName = requestClass.className;

                // Extract request fields
                RequestFieldInfo[] fields = extractRequestFields(requestClass);
                string paramKey = string `${method.name}::${param.name}`;

                // Apply cached LLM results
                string[] requiredFields = [];
                if requiredFieldsMap.hasKey(paramKey) {
                    string[]? reqFieldsVal = requiredFieldsMap.get(paramKey);
                    if reqFieldsVal is string[] {
                        requiredFields = reqFieldsVal;
                    }
                }

                RequestFieldInfo[] updatedFields = [];
                foreach RequestFieldInfo fld in fields {
                    RequestFieldInfo updated = fld;
                    // Check if this field is in the required list
                    boolean isReq = false;
                    foreach string reqField in requiredFields {
                        if fld.name == reqField {
                            isReq = true;
                            break;
                        }
                    }
                    updated.isRequired = isReq;
                    updatedFields.push(updated);
                }
                fields = updatedFields;

                RequestFieldInfo[] enhancedFields = [];

                foreach RequestFieldInfo fieldInfo in fields {
                    // Filter redundant AsString fields (e.g., aclAsString when acl exists)
                    if isRedundantAsStringField(fieldInfo.name, fields) {
                        continue;
                    }

                    RequestFieldInfo enhancedField = fieldInfo;

                    // Check if field type is an enum and extract enum values
                    ClassInfo? enumClass = findClassByName(fieldInfo.fullType, allClasses);
                    if enumClass is ClassInfo && enumClass.isEnum {
                        // Check if already cached
                        if !enumCache.hasKey(fieldInfo.fullType) {
                            // Extract enum metadata
                            EnumMetadata enumMeta = extractEnumMetadata(enumClass);
                            enumCache[fieldInfo.fullType] = enumMeta;
                        }
                        // Set enum reference
                        enhancedField.enumReference = fieldInfo.fullType;
                    }

                    // Check if field type is a collection (List, Set, Map, etc.) and extract memberReference
                    if isCollectionType(fieldInfo.typeName) {
                        string? genericParam = extractGenericTypeParameter(fieldInfo.fullType);
                        if genericParam is string && genericParam.length() > 0 {
                            // Verify the generic parameter class exists
                            ClassInfo? memberClass = findClassByName(genericParam, allClasses);
                            if memberClass is ClassInfo {
                                enhancedField.memberReference = genericParam;
                                // Cache the member class for extraction
                                if !memberClassCache.hasKey(genericParam) {
                                    memberClassCache[genericParam] = memberClass;
                                }
                            }
                        }
                    }

                    enhancedFields.push(enhancedField);
                }

                updatedParam.requestFields = enhancedFields;

                // If the parameter name is generic (e.g., 'consumer'), replace it with a sensible name
                if param.name.toLowerAscii().indexOf("consumer") != -1 || param.name.startsWith("arg") {
                    string simple = requestClass.simpleName;
                    if simple.length() > 0 {
                        string newName = simple.substring(0, 1).toLowerAscii() + simple.substring(1);
                        updatedParam.name = newName;
                    }
                }
            }

            updatedParams.push(updatedParam);
        }

        updatedMethod.parameters = updatedParams;

        // Populate returnFields for methods whose return type is a non-simple class
        RequestFieldInfo[] returnFields = [];
        if updatedMethod.returnType != "void" && !isSimpleType(updatedMethod.returnType) {
            ClassInfo? retCls = findClassByName(updatedMethod.returnType, allClasses);
            if retCls is ClassInfo {
                RequestFieldInfo[] rawReturnFields = extractResponseFields(retCls);

                // For any enum fields in the response, cache enum metadata and set enumReference
                // Also set memberReference for collection types
                RequestFieldInfo[] enhancedReturnFields = [];
                foreach RequestFieldInfo rf in rawReturnFields {
                    // Filter redundant AsString fields
                    if isRedundantAsStringField(rf.name, rawReturnFields) {
                        continue;
                    }

                    RequestFieldInfo enhancedRf = rf;
                    ClassInfo? enumClass = findClassByName(rf.fullType, allClasses);
                    if enumClass is ClassInfo && enumClass.isEnum {
                        if !enumCache.hasKey(rf.fullType) {
                            EnumMetadata enumMeta = extractEnumMetadata(enumClass);
                            enumCache[rf.fullType] = enumMeta;
                        }
                        enhancedRf.enumReference = rf.fullType;
                    }

                    // Check if field type is a collection (List, Set, Map, etc.) and extract memberReference
                    if isCollectionType(rf.typeName) {
                        string? genericParam = extractGenericTypeParameter(rf.fullType);
                        if genericParam is string && genericParam.length() > 0 {
                            // Verify the generic parameter class exists
                            ClassInfo? memberClass = findClassByName(genericParam, allClasses);
                            if memberClass is ClassInfo {
                                enhancedRf.memberReference = genericParam;
                                // Cache the member class for extraction
                                if !memberClassCache.hasKey(genericParam) {
                                    memberClassCache[genericParam] = memberClass;
                                }
                            }
                        }
                    }

                    enhancedReturnFields.push(enhancedRf);
                }
                returnFields = enhancedReturnFields;
            }
        }

        updatedMethod.returnFields = returnFields;
        methodsWithRequestFields.push(updatedMethod);
    }

    // resolve from allClasses
    foreach ConnectionFieldInfo connField in initPattern.connectionFields {
        if connField.enumReference is string {
            string enumRef = <string>connField.enumReference;
            if !enumCache.hasKey(enumRef) {
                ClassInfo? enumClass = findClassByName(enumRef, allClasses);
                if enumClass is () {
                    enumClass = resolveClassFromJars(enumRef, dependencyJarPaths);
                }
                if enumClass is ClassInfo && enumClass.isEnum {
                    enumCache[enumRef] = extractEnumMetadata(enumClass);
                }
            }
        }
        if connField.memberReference is string {
            string memberRef = <string>connField.memberReference;
            if !memberClassCache.hasKey(memberRef) {
                ClassInfo? memberClass = findClassByName(memberRef, allClasses);
                if memberClass is () {
                    memberClass = resolveClassFromJars(memberRef, dependencyJarPaths);
                }
                if memberClass is ClassInfo {
                    memberClassCache[memberRef] = memberClass;
                }
            }
        }
        if connField.typeReference is string {
            string typeRef = <string>connField.typeReference;
            ClassInfo? typeClass = findClassByName(typeRef, allClasses);
            if typeClass is () {
                typeClass = resolveClassFromJars(typeRef, dependencyJarPaths);
            }

            if typeClass is ClassInfo {
                if typeClass.isEnum {
                    if !enumCache.hasKey(typeRef) {
                        enumCache[typeRef] = extractEnumMetadata(typeClass);
                    }
                } else if !memberClassCache.hasKey(typeRef) {
                    memberClassCache[typeRef] = typeClass;
                }
            }
        }
    }

    // fill enum gaps with LLM-synthesized metadata
    foreach SyntheticTypeMetadata stm in initPattern.syntheticTypeMetadata {
        if stm.ballerinaType == "enum" && !enumCache.hasKey(stm.fullType) {
            string[] vals = stm.enumValues.length() > 0
                ? stm.enumValues
                : ["(see SDK documentation)"];
            enumCache[stm.fullType] = {
                simpleName: stm.simpleName,
                values: vals
            };
        }
    }

    // Extract JAR-resolved member classes (recursively) including external dependency classes
    map<MemberClassInfo> memberClasses = extractMemberClassInfo(
            memberClassCache,
            allClasses,
            dependencyJarPaths,
            enumCache
    );

    // Finalize enum metadata from resolved member classes as well, including
    // enum-like classes that expose public static final self-typed constants.
    foreach [string, ClassInfo] [memberName, memberClass] in memberClassCache.entries() {
        if enumCache.hasKey(memberName) {
            continue;
        }
        ClassInfo classForEnum = memberClass;
        if !classForEnum.isEnum && !hasEnumLikeConstants(classForEnum) {
            ClassInfo? refreshed = resolveClassFromJars(memberName, dependencyJarPaths);
            if refreshed is ClassInfo {
                classForEnum = refreshed;
            }
        }

        if classForEnum.isEnum || hasEnumLikeConstants(classForEnum) {
            EnumMetadata memberEnumMeta = extractEnumMetadata(classForEnum);
            if memberEnumMeta.values.length() > 0 {
                enumCache[memberName] = memberEnumMeta;
            }
        }
    }

    // Inject synthetic MemberClassInfo for record/object types
    foreach SyntheticTypeMetadata stm in initPattern.syntheticTypeMetadata {
        if (stm.ballerinaType == "record" || stm.ballerinaType == "object") &&
            !memberClasses.hasKey(stm.fullType) {
            string syntheticPkg = "";
            int? lastDot = stm.fullType.lastIndexOf(".");
            if lastDot is int && lastDot > 0 {
                syntheticPkg = stm.fullType.substring(0, lastDot);
            }
            memberClasses[stm.fullType] = {
                simpleName: stm.simpleName,
                packageName: syntheticPkg,
                fields: stm.subFields
            };
        }
    }

    return {
        sdkInfo: {
            name: extractSdkNameFromClass(rootClient),
            version: "unknown",
            rootClientClass: rootClient.className
        },
        clientInit: initPattern,
        rootClient: {
            className: rootClient.className,
            packageName: rootClient.packageName,
            simpleName: rootClient.simpleName,
            isInterface: rootClient.isInterface,
            constructors: rootClient.constructors,
            methods: methodsWithRequestFields
        },
        memberClasses: memberClasses,
        enums: enumCache,
        analysis: {
            totalClassesFound: allClasses.length(),
            totalMethodsInClient: rootClient.methods.length(),
            selectedMethods: methodsWithRequestFields.length(),
            analysisApproach: "JavaParser with LLM enhancement"
        }
    };
}

# Extract SDK name from class information
#
# + rootClient - Root client class
# + return - Inferred SDK name
function extractSdkNameFromClass(ClassInfo rootClient) returns string {
    string packageName = rootClient.packageName;
    if packageName == "" {
        return "Java SDK";
    }

    string[] parts = regex:split(packageName, "\\.");
    // Find last non-empty segment
    string last = "";
    foreach string p in parts.reverse() {
        if p.trim().length() > 0 {
            last = p;
            break;
        }
    }

    if last.length() == 0 {
        return "Java SDK";
    }

    // Title-case the last segment
    string namePart = last;
    if namePart.length() > 1 {
        string first = namePart.substring(0, 1).toUpperAscii();
        string rest = namePart.substring(1);
        namePart = first + rest;
    } else {
        namePart = namePart.toUpperAscii();
    }

    return namePart + " SDK";
}

# Extract supporting classes used by the selected methods
#
# + methods - Selected methods 
# + allClasses - All available classes
# + return - Supporting classes information
function extractSupportingClasses(MethodInfo[] methods, ClassInfo[] allClasses)
        returns SupportingClassInfo[] {

    SupportingClassInfo[] supportingClasses = [];
    map<boolean> addedClasses = {};

    foreach MethodInfo method in methods {
        // Check return type
        string returnType = method.returnType;
        if returnType != "void" && !isSimpleType(returnType) {
            ClassInfo? cls = findClassByName(returnType, allClasses);
            if cls is ClassInfo && !addedClasses.hasKey(cls.className) {
                supportingClasses.push({
                    className: cls.className,
                    simpleName: cls.simpleName,
                    packageName: cls.packageName,
                    purpose: "Return type"
                });
                addedClasses[cls.className] = true;
            }
        }

        // Check parameter types
        foreach ParameterInfo param in method.parameters {
            if !isSimpleType(param.typeName) {
                ClassInfo? cls = findClassByName(param.typeName, allClasses);
                if cls is ClassInfo && !addedClasses.hasKey(cls.className) {
                    supportingClasses.push({
                        className: cls.className,
                        simpleName: cls.simpleName,
                        packageName: cls.packageName,
                        purpose: "Parameter type"
                    });
                    addedClasses[cls.className] = true;
                }
            }
        }
    }

    return supportingClasses;
}

# Check if class should be considered as client candidate
#
# + cls - Class to check
# + return - True if should be considered
function shouldConsiderAsClientCandidate(ClassInfo cls) returns boolean {
    // Skip inner classes and enums
    if cls.className.includes("$") || cls.isEnum {
        return false;
    }

    // Skip abstract classes (but allow interfaces)
    if cls.isAbstract && !cls.isInterface {
        return false;
    }

    // Must have a minimum number of methods
    if cls.methods.length() < 3 {
        return false;
    }

    string simpleNameLower = cls.simpleName.toLowerAscii();
    string packageLower = cls.packageName.toLowerAscii();

    if isHelperLikeClientType(simpleNameLower) {
        return false;
    }

    boolean hasClientNameSignals = simpleNameLower.includes("client") || simpleNameLower.includes("admin") ||
        simpleNameLower.includes("producer") || simpleNameLower.includes("consumer") ||
        simpleNameLower.includes("service") || simpleNameLower.includes("manager") ||
        simpleNameLower.includes("connection");
    boolean hasClientPackageSignals = packageLower.includes(".clients") || packageLower.includes(".client") ||
        packageLower.includes(".admin") || packageLower.includes(".consumer") ||
        packageLower.includes(".producer");

    if cls.isInterface {
        if cls.methods.length() >= 5 && (hasClientNameSignals || hasClientPackageSignals || cls.methods.length() >= 12) {
            return true;
        }
    } else {
        if cls.methods.length() >= 6 && (hasClientNameSignals || hasClientPackageSignals) {
            return true;
        }
        if cls.methods.length() >= 18 && hasClientPackageSignals {
            return true;
        }
    }

    if cls.methods.length() >= 25 && (hasClientNameSignals || hasClientPackageSignals) {
        return true;
    }

    return false;
}

function quickClientCandidatePriority(ClassInfo cls) returns int {
    string simpleNameLower = cls.simpleName.toLowerAscii();
    string packageLower = cls.packageName.toLowerAscii();

    int priority = cls.methods.length();
    if priority > 100 {
        priority = 100;
    }

    if simpleNameLower.includes("client") {
        priority += 40;
    }
    if simpleNameLower.includes("admin") || simpleNameLower.includes("producer") ||
        simpleNameLower.includes("consumer") {
        priority += 35;
    }
    if packageLower.includes(".clients") || packageLower.includes(".client") {
        priority += 25;
    }
    if cls.isInterface {
        priority += 10;
    }

    return priority;
}

function isHelperLikeClientType(string simpleNameLower) returns boolean {
    string[] helperTokens = ["builder", "config", "option", "request", "response", "result", "record",
        "metadata", "context", "factory", "provider", "interceptor", "serializer", "deserializer",
        "authenticator", "readable", "writable", "util", "helper"];
    foreach string token in helperTokens {
        if simpleNameLower.includes(token) {
            return true;
        }
    }
    return false;
}

# Check if Anthropic LLM is properly configured
#
# + return - True if configured
function isAnthropicConfigured() returns boolean {
    // Check environment variable first
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey is string {
        if apiKey.trim().length() > 0 {
            return true;
        }
    }

    // If getAnthropicConfig returns a config, then Anthropic is configured.
    AnthropicConfiguration|error conf = getAnthropicConfig();
    if conf is AnthropicConfiguration {
        return true;
    }

    return false;
}

# Use LLM to detect client initialization pattern and generate example code.
#
# + rootClient - The identified root client class  
# + allClasses - All classes for context
# + dependencyJarPaths - Paths to dependency JARs for deeper analysis if needed
# + return - Detected initialization pattern with example code or error
function detectInitPatternWithLLM(
        ClassInfo rootClient,
        ClassInfo[] allClasses,
        string[] dependencyJarPaths
) returns ClientInitPattern|error {
    if isAnthropicConfigured() {
        string systemPrompt = getInitPatternSystemPrompt();
        string constructorDetails = formatConstructorDetails(rootClient.constructors);
        string staticMethodInfo = formatStaticMethods(rootClient.methods);
        string userPrompt = getInitPatternUserPrompt(
                rootClient.simpleName,
                rootClient.packageName,
                constructorDetails,
                staticMethodInfo,
                rootClient.methods.length(),
                rootClient.isInterface
        );

        json|error response = callAnthropicAPI(check getAnthropicConfig(), systemPrompt, userPrompt);

        if response is json {
            string responseText = extractResponseText(response);
            string[] lines = regex:split(responseText, "\n");
            string patternName = "";
            string reason = "";

            foreach string line in lines {
                string trimmed = line.trim();
                if trimmed.startsWith("PATTERN:") {
                    patternName = trimmed.substring(8).trim().toLowerAscii();
                } else if trimmed.startsWith("REASON:") {
                    reason = trimmed.substring(7).trim();
                }
            }

            if patternName == "constructor" || patternName == "builder" ||
                patternName == "static-factory" || patternName == "instance-factory" ||
                patternName == "no-constructor" {
                string initCode = generateInitializationCode(patternName, rootClient);
                ClientInitPattern llmPattern = {
                    patternName: patternName,
                    initializationCode: initCode,
                    explanation: reason == "" ? "Pattern detected by LLM analysis" : reason,
                    detectedBy: "llm"
                };
                if patternName == "builder" || patternName == "static-factory" ||
                    patternName == "constructor" {
                    [string?, ConnectionFieldInfo[], SyntheticTypeMetadata[]] br =
                        resolveBuilderConnectionFields(
                            rootClient, allClasses, dependencyJarPaths,
                            rootClient.packageName, rootClient.simpleName
                        );
                    llmPattern.builderClass = br[0];
                    llmPattern.connectionFields = br[1];
                    llmPattern.syntheticTypeMetadata = br[2];
                }
                return llmPattern;
            }
        } else {
            error err = <error>response;
            io:println(string `LLM init pattern detection failed: ${err.message()}`);
        }
    }

    // Fallback to heuristic
    ClientInitPattern heuristicPattern = detectClientInitPatternHeuristically(rootClient);
    if heuristicPattern.patternName == "builder" || heuristicPattern.patternName == "static-factory" ||
        heuristicPattern.patternName == "constructor" {
        [string?, ConnectionFieldInfo[], SyntheticTypeMetadata[]] br =
            resolveBuilderConnectionFields(
                rootClient, allClasses, dependencyJarPaths,
                rootClient.packageName, rootClient.simpleName
            );
        heuristicPattern.builderClass = br[0];
        heuristicPattern.connectionFields = br[1];
        heuristicPattern.syntheticTypeMetadata = br[2];
    }
    return heuristicPattern;
}

# Use LLM to intelligently rank SDK methods by usage frequency and examples
#
# + methods - Methods to rank
# + return - Ranked methods or error
function rankMethodsUsingLLM(MethodInfo[] methods) returns MethodInfo[]|error {
    string systemPrompt = getMethodRankingSystemPrompt();
    string methodsList = formatMethodsListForRanking(methods);
    string userPrompt = getMethodRankingUserPrompt(methods.length(), methodsList);

    json|error response = callAnthropicAPI(check getAnthropicConfig(), systemPrompt, userPrompt);

    if response is json {
        string responseText = extractResponseText(response);
        if responseText == "" {
            responseText = response.toString();
        }

        // Parse the comma-separated method names
        string[] rankedNames = regex:split(responseText, ",");
        string[] trimmedNames = rankedNames.map(n => n.trim()).filter(n => n.length() > 0);

        if trimmedNames.length() > 0 {
            // Create a map for quick lookup
            map<MethodInfo> methodMap = {};
            foreach MethodInfo method in methods {
                methodMap[method.name] = method;
            }

            // Build result maintaining LLM's priority order, limited to first 40 methods
            MethodInfo[] reordered = [];
            foreach string methodName in trimmedNames {
                if reordered.length() >= 40 {
                    break;
                }
                if methodMap.hasKey(methodName) {
                    MethodInfo? method = methodMap[methodName];
                    if method is MethodInfo {
                        reordered.push(method);
                    }
                }
            }

            // Now fetch descriptions for the selected methods
            MethodInfo[] withDescriptions = check addMethodDescriptions(reordered);
            return withDescriptions;
        }
    }

    return error("Failed to rank methods using LLM");
}

# Fetch descriptions for selected methods from LLM (only for methods without descriptions)
#
# + methods - Selected methods to get descriptions for
# + return - Methods with descriptions added
function addMethodDescriptions(MethodInfo[] methods) returns MethodInfo[]|error {
    if methods.length() == 0 {
        return methods;
    }

    // Identify methods that need descriptions (don't have javadoc descriptions)
    MethodInfo[] needsDescription = [];
    int[] needsDescriptionIndices = [];
    foreach int i in 0 ..< methods.length() {
        if methods[i].description is () || methods[i].description == "" {
            needsDescription.push(methods[i]);
            needsDescriptionIndices.push(i);
        }
    }

    // If all methods have descriptions, return as-is
    if needsDescription.length() == 0 {
        return methods;
    }

    // If LLM not configured, return methods as-is
    if !isAnthropicConfigured() {
        return methods;
    }

    // Build method list with signatures for methods needing descriptions
    string methodList = "";
    foreach int i in 0 ..< needsDescription.length() {
        MethodInfo m = needsDescription[i];
        string paramTypes = "";
        if m.parameters.length() > 0 {
            string[] pTypes = [];
            foreach ParameterInfo p in m.parameters {
                pTypes.push(p.typeName);
            }
            paramTypes = string:'join(", ", ...pTypes);
        }
        methodList = methodList + (i + 1).toString() + ". " + m.name + "(" + paramTypes + ") -> " + m.returnType + "\n";
    }

    string systemPrompt = "You are a Java SDK expert. Provide one-line descriptions for the given methods. " +
        "Each description should clearly explain what the method does in user-friendly language. " +
        "Return ONLY the descriptions, one per line, in the same order as the input methods. " +
        "Do not include method names or numbers, just pure descriptions.";

    string userPrompt = "Provide one-line descriptions for these methods:\n\n" + methodList +
        "\nDescriptions (one per line, in same order):";

    json|error response = callAnthropicAPI(check getAnthropicConfig(), systemPrompt, userPrompt);

    if response is json {
        string responseText = extractResponseText(response).trim();
        if responseText != "" {
            string[] descriptions = regex:split(responseText, "\n");
            descriptions = descriptions.map(d => d.trim()).filter(d => d.length() > 0);

            // Apply LLM descriptions only to methods that needed them
            MethodInfo[] result = methods.clone();
            foreach int i in 0 ..< needsDescriptionIndices.length() {
                if i < descriptions.length() {
                    int methodIndex = needsDescriptionIndices[i];
                    result[methodIndex].description = descriptions[i];
                }
            }
            return result;
        }
    }

    // Return methods without descriptions if LLM call fails
    return methods;
}

# Ask LLM to select the top-N most-used methods from the provided list.
#
# + methods - All methods 
# + n - Number of methods to select
# + return - Selected top-N methods or error
function selectTopNMethodsWithLLM(MethodInfo[] methods, int n) returns MethodInfo[]|error {
    if n <= 0 {
        return error("Invalid n passed to selectTopNMethodsWithLLM");
    }

    if methods.length() == 0 {
        return methods;
    }

    if !isAnthropicConfigured() {
        return error("Anthropic LLM not configured: cannot select top-N methods");
    }

    string systemPrompt = getMethodRankingSystemPrompt();
    string methodsList = formatMethodsListForRanking(methods);
    string userPrompt = getMethodSelectionUserPrompt(methods.length(), methodsList, n);

    json|error response = callAnthropicAPI(check getAnthropicConfig(), systemPrompt, userPrompt);
    if response is json {
        string responseText = extractResponseText(response).trim();
        if responseText == "" {
            responseText = response.toString();
        }

        // Parse comma-separated method names
        string[] parts = regex:split(responseText, ",");
        string[] trimmed = parts.map(p => p.trim()).filter(p => p.length() > 0);

        if trimmed.length() == 0 {
            return error("LLM returned no method names for top-N selection");
        }

        // Map names to MethodInfo by exact match on name
        map<MethodInfo> methodMap = {};
        foreach MethodInfo m in methods {
            methodMap[m.name] = m;
        }

        MethodInfo[] selected = [];
        foreach string name in trimmed {
            if methodMap.hasKey(name) {
                MethodInfo? mm = methodMap[name];
                if mm is MethodInfo {
                    selected.push(mm);
                }
            }
            if selected.length() == n {
                break;
            }
        }

        // If LLM returned fewer valid names than n, fall back to filling from original list
        if selected.length() < n {
            foreach MethodInfo m in methods {
                // avoid duplicates
                boolean found = false;
                foreach MethodInfo s in selected {
                    if s.name == m.name {
                        found = true;
                        break;
                    }
                }
                if !found {
                    selected.push(m);
                }
                if selected.length() == n {
                    break;
                }
            }
        }

        return selected;
    }

    return error("Failed to call LLM for top-N method selection");
}

# Heuristic-based client initialization pattern detection
#
# + clientClass - The client class to analyze
# + return - Detected initialization pattern
function detectClientInitPatternHeuristically(ClassInfo clientClass) returns ClientInitPattern {
    // Prefer detecting builder/static-factory patterns via presence of static methods
    foreach MethodInfo m in clientClass.methods {
        if m.isStatic {
            string nameLower = m.name.toLowerAscii();
            // static builder() method (common in AWS SDK v2)
            if nameLower == "builder" {
                return {
                    patternName: "builder",
                    initializationCode: clientClass.simpleName + " client = " + clientClass.simpleName + ".builder().build();",
                    explanation: "Detected static builder() method",
                    detectedBy: "heuristic"
                };
            }
            // static create() or createX factory method
            if nameLower == "create" || nameLower.startsWith("create") {
                return {
                    patternName: "static-factory",
                    initializationCode: clientClass.simpleName + " client = " + clientClass.simpleName + ".create();",
                    explanation: "Detected static create() factory method",
                    detectedBy: "heuristic"
                };
            }
        }
    }

    // Fall back to constructors if present
    if clientClass.constructors.length() == 0 {
        return {
            patternName: "no-constructor",
            initializationCode: "// No public constructors found",
            explanation: "The class does not expose public constructors",
            detectedBy: "heuristic"
        };
    }

    string[] patterns = [];
    string[] codePatterns = [];
    foreach ConstructorInfo constructor in clientClass.constructors {
        if constructor.parameters.length() == 0 {
            patterns.push("Default constructor");
            codePatterns.push(string `new ${clientClass.simpleName}()`);
        } else {
            string[] paramTypes = constructor.parameters.map(p => p.typeName);
            patterns.push(string `Constructor(${string:'join(", ", ...paramTypes)})`);
            string[] paramNames = constructor.parameters.map(p => p.name);
            codePatterns.push(string `new ${clientClass.simpleName}(${string:'join(", ", ...paramNames)})`);
        }
    }

    return {
        patternName: "constructor",
        initializationCode: string:'join(" // OR\n", ...codePatterns),
        explanation: string:'join(" | ", ...patterns),
        detectedBy: "heuristic"
    };
}

# Analyze fields using LLM to determine if they are required or optional
#
# + methodName - Method name for context
# + parameterType - Parameter type name
# + fields - Array of request fields to analyze
# + config - Analyzer configuration
# + return - Updated fields with isRequired set by LLM
public function analyzeFieldRequirements(
        string methodName,
        string parameterType,
        RequestFieldInfo[] fields,
        AnalyzerConfig config
) returns RequestFieldInfo[]|error {

    if config.disableLLM || fields.length() == 0 {
        return fields;
    }

    // Build field list for prompt
    string fieldsList = "";
    foreach RequestFieldInfo fld in fields {
        fieldsList += string `- ${fld.name}: ${fld.typeName}\n`;
    }

    // Get LLM config
    AnthropicConfiguration llmConfig = check getAnthropicConfig();

    // Call LLM
    string sysPrompt = getFieldRequirementSystemPrompt();
    string userPrompt = getFieldRequirementUserPrompt(methodName, parameterType, fieldsList);
    json|error llmResponse = callAnthropicAPI(llmConfig, sysPrompt, userPrompt);

    if llmResponse is error {
        // If LLM fails, return original fields
        return fields;
    }

    // Parse LLM response
    string responseText = extractResponseText(llmResponse);

    // Extract JSON array from response (handle markdown code blocks)
    string jsonText = responseText.trim();
    if jsonText.startsWith("```json") {
        jsonText = jsonText.substring(7);
    }
    if jsonText.startsWith("```") {
        jsonText = jsonText.substring(3);
    }
    if jsonText.endsWith("```") {
        jsonText = jsonText.substring(0, jsonText.length() - 3);
    }
    jsonText = jsonText.trim();

    json|error parsedJson = jsonText.fromJsonString();
    if parsedJson is error {
        // If parsing fails, return original fields
        return fields;
    }

    // Parse the JSON array and update fields
    if parsedJson is json[] {
        map<boolean> requirementMap = {};

        foreach json item in parsedJson {
            if item is map<json> {
                string? fieldName = <string?>item["field"];
                boolean? required = <boolean?>item["required"];

                if fieldName is string && required is boolean {
                    requirementMap[fieldName] = required;
                }
            }
        }

        // Update fields with LLM results
        RequestFieldInfo[] updatedFields = [];
        foreach RequestFieldInfo fld in fields {
            RequestFieldInfo updated = fld;
            if requirementMap.hasKey(fld.name) {
                updated.isRequired = requirementMap.get(fld.name);
            }
            updatedFields.push(updated);
        }

        return updatedFields;
    }

    return fields;
}

# Check if a field is a redundant "AsString" variant of another field
#
# + fieldName - Field name to check
# + allFields - All fields in the same context
# + return - True if this field should be filtered out
function isRedundantAsStringField(string fieldName, RequestFieldInfo[] allFields) returns boolean {
    // Check if field name ends with "AsString" or "AsStrings"
    if !fieldName.endsWith("AsString") && !fieldName.endsWith("AsStrings") {
        return false;
    }

    // Extract the base field name (remove AsString/AsStrings suffix)
    string baseFieldName;
    if fieldName.endsWith("AsStrings") {
        baseFieldName = fieldName.substring(0, fieldName.length() - 9);
    } else {
        baseFieldName = fieldName.substring(0, fieldName.length() - 8);
    }

    // Check if the base field exists
    foreach RequestFieldInfo fld in allFields {
        if fld.name == baseFieldName {
            // Base field exists, this AsString variant is redundant
            return true;
        }
    }

    return false;
}

# Extract member class information from cached member classes
#
# + memberClassCache - Map of class names to ClassInfo
# + allClasses - All parsed classes from the main analysis
# + dependencyJarPaths - Dependency JAR paths for resolving external types
# + enumCache - Mutable enum cache to record discovered nested enums
# + return - Map of member class info with extracted fields
function extractMemberClassInfo(
        map<ClassInfo> memberClassCache,
        ClassInfo[] allClasses,
        string[] dependencyJarPaths,
        map<EnumMetadata> enumCache
) returns map<MemberClassInfo> {
    map<MemberClassInfo> result = {};

    // Traverse recursively over cached member classes, expanding nested non-primitive types
    // until primitive/standard Java leaf types are reached.
    string[] pending = memberClassCache.keys();
    int index = 0;

    while index < pending.length() {
        string className = pending[index];
        ClassInfo? classInfoOpt = memberClassCache[className];
        if classInfoOpt is () {
            index += 1;
            continue;
        }
        ClassInfo classInfo = classInfoOpt;

        RequestFieldInfo[] extractedFields;

        // For enums, extract the actual enum constants from the fields array
        if classInfo.isEnum {
            extractedFields = extractEnumConstants(classInfo);
        } else {
            // For regular classes, extract fields from getter methods
            extractedFields = extractResponseFields(classInfo);
        }

        // Filter redundant AsString fields from member class fields too
        RequestFieldInfo[] filteredFields = [];
        foreach RequestFieldInfo fld in extractedFields {
            if isRedundantAsStringField(fld.name, extractedFields) {
                continue;
            }

            RequestFieldInfo enhanced = fld;

            // Resolve collection generic member types (e.g., List<Foo>)
            if isCollectionType(fld.typeName) {
                string? genericParam = extractGenericTypeParameter(fld.fullType);
                if genericParam is string && genericParam.length() > 0 {
                    enhanced.memberReference = genericParam;

                    ClassInfo? memberClass = findClassByName(genericParam, allClasses);
                    if memberClass is () {
                        memberClass = resolveClassFromJars(genericParam, dependencyJarPaths);
                    }

                    if memberClass is ClassInfo {
                        if memberClass.isEnum || hasEnumLikeConstants(memberClass) {
                            if memberClass.isEnum {
                                enhanced.enumReference = genericParam;
                            }
                            if !enumCache.hasKey(genericParam) {
                                enumCache[genericParam] = extractEnumMetadata(memberClass);
                            }
                        } else if memberClass.className != className &&
                                !memberClassCache.hasKey(genericParam) {
                            memberClassCache[genericParam] = memberClass;
                            pending.push(genericParam);
                        }
                    }
                }
            } else if !isSimpleType(fld.fullType) && !isStandardJavaType(fld.fullType) {
                // Resolve nested object/enum fields recursively
                ClassInfo? nestedClass = findClassByName(fld.fullType, allClasses);
                if nestedClass is () {
                    nestedClass = resolveClassFromJars(fld.fullType, dependencyJarPaths);
                }

                if nestedClass is ClassInfo {
                    if nestedClass.isEnum || hasEnumLikeConstants(nestedClass) {
                        if nestedClass.isEnum {
                            enhanced.enumReference = fld.fullType;
                        }
                        if !enumCache.hasKey(fld.fullType) {
                            enumCache[fld.fullType] = extractEnumMetadata(nestedClass);
                        }
                    } else {
                        enhanced.memberReference = fld.fullType;
                        if nestedClass.className != className &&
                            !memberClassCache.hasKey(fld.fullType) {
                            memberClassCache[fld.fullType] = nestedClass;
                            pending.push(fld.fullType);
                        }
                    }
                }
            }

            filteredFields.push(enhanced);
        }

        MemberClassInfo memberInfo = {
            simpleName: classInfo.simpleName,
            packageName: classInfo.packageName,
            fields: filteredFields
        };

        result[className] = memberInfo;

        index += 1;
    }

    return result;
}

# Resolve connection fields for builder pattern using LLM enrichment.
#
# + clientClass - The client ClassInfo for which to resolve builder connection fields 
# + allClasses - All classes available
# + dependencyJarPaths - Paths to dependency JARs for deeper analysis if needed
# + sdkPackage - The SDK package name
# + clientSimpleName - The simple name of the client class
# + return - The resolved connection fields and synthetic type metadata
function resolveBuilderConnectionFields(
        ClassInfo clientClass,
        ClassInfo[] allClasses,
        string[] dependencyJarPaths,
        string sdkPackage,
        string clientSimpleName
) returns [string?, ConnectionFieldInfo[], SyntheticTypeMetadata[]] {

    ClassInfo? builderClass = findBuilderClass(clientClass, allClasses, dependencyJarPaths);
    if builderClass is () {
        return [(), [], []];
    }

    ConnectionFieldInfo[] fields = [];
    map<boolean> visitedClasses = {};
    map<boolean> visitedFieldNames = {};
    ClassInfo[] resolvedClasses = [...allClasses];

    collectBuilderSetters(
            builderClass, resolvedClasses, dependencyJarPaths,
            fields, visitedClasses, visitedFieldNames, 0
    );

    if fields.length() == 0 {
        return [builderClass.className, [], []];
    }

    // Enrich ALL fields via a single batched LLM call.
    // Returns both the enriched fields and synthetic type metadata.
    [ConnectionFieldInfo[], SyntheticTypeMetadata[]] enrichResult =
        enrichConnectionFieldsWithLLM(fields, sdkPackage, clientSimpleName);

    ConnectionFieldInfo[] enrichedFields = enrichResult[0];
    SyntheticTypeMetadata[] syntheticMeta = enrichResult[1];

    // Strip the internal level1Context before returning.
    ConnectionFieldInfo[] clean = [];
    foreach ConnectionFieldInfo f in enrichedFields {
        ConnectionFieldInfo stripped = {
            name: f.name,
            typeName: f.typeName,
            fullType: f.fullType,
            isRequired: f.isRequired,
            enumReference: f.enumReference,
            memberReference: f.memberReference,
            typeReference: f.typeReference,
            description: f.description
            // level1Context intentionally omitted
        };
        clean.push(stripped);
    }

    return [builderClass.className, clean, syntheticMeta];
}

# Find the builder class for a client class.
#
# + clientClass - The client ClassInfo to find a builder for 
# + allClasses - All classes available (for hierarchy lookup)
# + dependencyJarPaths - Paths to dependency JARs for resolving external classes
# + return - The builder ClassInfo if found, otherwise ()
function findBuilderClass(ClassInfo clientClass, ClassInfo[] allClasses, string[] dependencyJarPaths) returns ClassInfo? {
    // Strategy 1: static builder() method return type
    foreach MethodInfo m in clientClass.methods {
        if m.isStatic && m.name == "builder" && m.returnType != "void" {
            ClassInfo? found = findClassByName(m.returnType, allClasses);
            if found is ClassInfo {
                return found;
            }
            // returnType may be a simple name, try qualifying with client package
            string qualified = clientClass.packageName + "." + m.returnType;
            found = findClassByName(qualified, allClasses);
            if found is ClassInfo {
                return found;
            }
            // Try to resolve from dependency JARs
            found = resolveClassFromJars(m.returnType, dependencyJarPaths);
            if found is ClassInfo {
                return found;
            }
            found = resolveClassFromJars(qualified, dependencyJarPaths);
            if found is ClassInfo {
                return found;
            }
        }
    }

    // Strategy 2: name-convention search for Builder in same package
    string clientSimple = clientClass.simpleName;
    foreach ClassInfo cls in allClasses {
        string sn = cls.simpleName;
        if (sn == clientSimple + "Builder" || sn == clientSimple + "$Builder") &&
            cls.packageName == clientClass.packageName {
            return cls;
        }
    }

    // Strategy 3: any Builder in same package whose name contains the client name
    foreach ClassInfo cls in allClasses {
        if cls.simpleName.endsWith("Builder") &&
            cls.packageName == clientClass.packageName &&
            cls.simpleName.includes(clientSimple) {
            return cls;
        }
    }

    return ();
}

# Recursively collect setter-style methods from a builder class and its ancestors.
#
# + builderClass - The current builder ClassInfo to analyze  
# + resolvedClasses - Mutable array of all resolved classes
# + dependencyJarPaths - Paths to dependency JARs for resolving external classes
# + fields - The collected ConnectionFieldInfo array
# + visitedClasses - Map of visited class names to prevent infinite loops
# + visitedFieldNames - Map of visited field names to prevent duplicates
# + depth - The current recursion depth
function collectBuilderSetters(
        ClassInfo builderClass,
        ClassInfo[] resolvedClasses,
        string[] dependencyJarPaths,
        ConnectionFieldInfo[] fields,
        map<boolean> visitedClasses,
        map<boolean> visitedFieldNames,
        int depth
) {
    int maxDepth = 8;
    if depth > maxDepth {
        return;
    }
    if visitedClasses.hasKey(builderClass.className) {
        return;
    }
    visitedClasses[builderClass.className] = true;

    foreach FieldInfo fld in builderClass.fields {
        if fld.isStatic {
            continue;
        }
        string fieldName = fld.name;
        if fieldName.startsWith("$") || fieldName.startsWith("_") {
            continue;
        }
        if visitedFieldNames.hasKey(fieldName) {
            continue;
        }
        if shouldFilterField(fieldName, fld.typeName) {
            continue;
        }
        visitedFieldNames[fieldName] = true;

        string paramSimple = extractSimpleTypeName(fld.typeName);
        ClassInfo? resolvedClass = findOrResolveClass(fld.typeName, resolvedClasses, dependencyJarPaths);
        string level1Ctx = resolvedClass is ClassInfo ? buildLevel1Context(resolvedClass) : "";

        ConnectionFieldInfo info = {
            name: fieldName,
            typeName: paramSimple,
            fullType: fld.typeName,
            isRequired: false,
            description: fld.javadoc,
            level1Context: level1Ctx
        };

        if !isPrimitiveType(fld.typeName) {
            if isCollectionType(paramSimple) {
                string? genericParam = extractGenericTypeParameter(fld.typeName);
                if genericParam is string && genericParam.length() > 0 {
                    ClassInfo? memberClass = findOrResolveClass(genericParam, resolvedClasses, dependencyJarPaths);
                    if memberClass is ClassInfo {
                        info.memberReference = genericParam;
                    }
                }
            } else if !isStandardJavaType(fld.typeName) {
                // Set typeReference regardless of whether the class resolved.
                // enrichConnectionFieldsWithLLM will correct this later.
                info.typeReference = fld.typeName;
                if resolvedClass is ClassInfo && resolvedClass.isEnum {
                    info.enumReference = fld.typeName;
                    info.typeReference = ();
                }
            }
        }

        fields.push(info);
    }

    // Setter-style methods
    string[] utilityMethods = [
        "build",
        "tostring",
        "hashcode",
        "equals",
        "close",
        "copy",
        "applymutation",
        "sdkfields",
        "sdkfieldnameconstants",
        "get",
        "set",
        "create",
        "validate",
        "from",
        "of",
        "with"
    ];

    foreach MethodInfo m in builderClass.methods {
        if m.isStatic {
            continue;
        }
        if m.parameters.length() != 1 {
            continue;
        }

        string methodNameLower = m.name.toLowerAscii();
        boolean isUtility = false;
        foreach string util in utilityMethods {
            if methodNameLower == util || methodNameLower.startsWith("get") ||
                methodNameLower.startsWith("set") || methodNameLower.startsWith("on") {
                isUtility = true;
                break;
            }
        }
        if isUtility {
            continue;
        }

        string fieldName = m.name;
        if fieldName.startsWith("$") || fieldName.startsWith("_") {
            continue;
        }

        string paramFullType = m.parameters[0].typeName;
        string paramSimple = extractSimpleTypeName(paramFullType);

        // Consumer/Supplier functional interfaces cannot be represented as fields.
        if paramSimple == "Consumer" || paramSimple.endsWith("Consumer") || paramSimple == "Supplier" {
            continue;
        }

        if shouldFilterField(fieldName, paramFullType) {
            continue;
        }
        if visitedFieldNames.hasKey(fieldName) {
            continue;
        }
        visitedFieldNames[fieldName] = true;

        ClassInfo? paramTypeClass = findOrResolveClass(paramFullType, resolvedClasses, dependencyJarPaths);
        // level1Context is always a non-null string
        string level1Ctx = paramTypeClass is ClassInfo ? buildLevel1Context(paramTypeClass) : "";

        ConnectionFieldInfo info = {
            name: fieldName,
            typeName: paramSimple,
            fullType: paramFullType,
            isRequired: false,
            description: m.description,
            level1Context: level1Ctx
        };

        if !isPrimitiveType(paramFullType) {
            if isCollectionType(paramSimple) {
                string? genericParam = extractGenericTypeParameter(paramFullType);
                if genericParam is string && genericParam.length() > 0 {
                    ClassInfo? memberClass = findOrResolveClass(genericParam, resolvedClasses, dependencyJarPaths);
                    if memberClass is ClassInfo {
                        info.memberReference = genericParam;
                    }
                }
            } else if !isStandardJavaType(paramFullType) {
                // Set typeReference regardless of resolution outcome.
                // enrichConnectionFieldsWithLLM corrects this based on ballerinaType.
                info.typeReference = paramFullType;
                if paramTypeClass is ClassInfo && paramTypeClass.isEnum {
                    info.enumReference = paramFullType;
                    info.typeReference = ();
                }
            }
        }

        fields.push(info);
    }

    // Superclass recursion
    string? superClass = builderClass.superClass;
    if superClass is string && superClass != "java.lang.Object" && superClass != "" {
        ClassInfo? superInfo = findOrResolveClass(superClass, resolvedClasses, dependencyJarPaths);
        if superInfo is ClassInfo {
            collectBuilderSetters(superInfo, resolvedClasses, dependencyJarPaths,
                    fields, visitedClasses, visitedFieldNames, depth + 1);
        }
    }

    // Interface recursion
    foreach string iface in builderClass.interfaces {
        string ifaceName = iface;
        int? angleIdx = iface.indexOf("<");
        if angleIdx is int && angleIdx > 0 {
            ifaceName = iface.substring(0, angleIdx);
        }
        if ifaceName == "java.lang.Object" || ifaceName == "" {
            continue;
        }
        ClassInfo? ifaceInfo = findOrResolveClass(ifaceName, resolvedClasses, dependencyJarPaths);
        if ifaceInfo is ClassInfo {
            collectBuilderSetters(ifaceInfo, resolvedClasses, dependencyJarPaths,
                    fields, visitedClasses, visitedFieldNames, depth + 1);
        }
    }
}
