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

import ballerina/regex;

# Resolve an underlying Request/Response ClassInfo from a parameter
#
# + param - Parameter to analyze
# + allClasses - All classes for type lookup
# + methodName - Method name for heuristics
# + return - Resolved class or null
public function resolveRequestClassFromParameter(ParameterInfo param, ClassInfo[] allClasses, string methodName)
    returns ClassInfo? {
    string[] candidates = [];

    // Add the parameter's declared type first
    if param.typeName != "" {
        candidates.push(param.typeName);
    }

    // For each candidate type name, generate normalized forms to try to match
    // known Request/Response types.
    foreach string raw in candidates {
        string[] normCandidates = normalizeCandidateTypeNames(raw);
        foreach string cand in normCandidates {
            // Prefer explicit Request/Response names, but allow matching by simple name
            if cand.endsWith("Request") || cand.endsWith("Response") {
                ClassInfo? found = findClassByName(cand, allClasses);
                if found is ClassInfo {
                    return found;
                }
            }
        }
    }

    // If any candidate directly matches a class, return it (non-Request too)
    foreach string raw in candidates {
        ClassInfo? found = findClassByName(raw, allClasses);
        if found is ClassInfo {
            return found;
        }
    }

    // If no generics were present or matched, and the parameter type is a
    // common wrapper, try to derive a request type
    if candidates.length() == 1 {
        string rawOnly = candidates[0];
        string lower = rawOnly.toLowerAscii();
        if lower.includes("consumer") || lower.includes("function") || lower.includes("supplier") {
            // Generate PascalCase method name
            string pascal = methodName.substring(0,1).toUpperAscii() + methodName.substring(1);
            string guess = pascal + "Request";
            ClassInfo? guessCls = findClassByName(guess, allClasses);
            if guessCls is ClassInfo {
                return guessCls;
            }
        }
    }

    return null;
}

# Normalize a type name to candidates for lookup
#
# + raw - Raw type name
# + return - Array of normalized candidate names
public function normalizeCandidateTypeNames(string raw) returns string[] {
    string[] out = [];
    if raw == "" {
        return out;
    }

    if raw.includes("<") && raw.includes(">") {
        string[] parts = regex:split(raw, "<|>");
        if parts.length() >= 2 {
            string inner = parts[1];
            out.push(inner);
        }
        string withoutGenerics = regex:replace(raw, "<.*>", "");
        out.push(withoutGenerics);
    }

    // Add original raw
    out.push(raw);

    if raw.endsWith(".Builder") {
        string removed = regex:replace(raw, "\\.Builder$", "");
        out.push(removed);
    } else if raw.endsWith("Builder") {
        if raw.includes("$") {
            string maybe = regex:replace(raw, "\\$Builder$", "");
            if maybe != raw {
                out.push(maybe);
            }
        }
        string stripped = regex:replace(raw, "Builder$", "");
        out.push(stripped);
    }

    // If contains '$' (inner class), also try replacing with '.' and stripping suffixes
    if raw.includes("$") {
        string dotForm = regex:replace(raw, "\\$", ".");
        out.push(dotForm);
        if dotForm.endsWith(".Builder") {
            string removedDotBuilder = regex:replace(dotForm, "\\.Builder$", "");
            out.push(removedDotBuilder);
        }
    }

    // Also add simple name candidate (strip package)
    string[] parts = regex:split(raw, "\\.");
    if parts.length() > 0 {
        string simple = parts[parts.length() - 1];
        out.push(simple);
        if simple.endsWith("Builder") {
            string simpleStripped = regex:replace(simple, "Builder$", "");
            out.push(simpleStripped);
        }
    }

    // Remove duplicates while preserving order
    string[] uniq = [];
    foreach string s in out {
        if s == "" {
            continue;
        }
        boolean present = uniq.some(function(string x) returns boolean { return x == s; });
        if !present {
            uniq.push(s);
        }
    }

    return uniq;
}

# Find class by name in the class list
#
# + className - Class name to find
# + allClasses - All available classes
# + return - Found class or null
public function findClassByName(string className, ClassInfo[] allClasses) returns ClassInfo? {
    foreach ClassInfo cls in allClasses {
        if cls.className == className || cls.simpleName == className {
            return cls;
        }
    }
    return null;
}

# Extract request fields from a Request class
#
# + requestClass - The Request class to analyze
# + return - List of request field information
public function extractRequestFields(ClassInfo requestClass) returns RequestFieldInfo[] {
    RequestFieldInfo[] requestFields = [];

    foreach MethodInfo method in requestClass.methods {
        if method.parameters.length() == 0 && method.returnType != "void" &&
           method.name != "toString" && method.name != "hashCode" &&
           method.name != "equals" && method.name != "getClass" {

            // Filter out unwanted utility methods
            if shouldFilterField(method.name, method.returnType) {
                continue;
            }

            string fieldName = method.name;
            if fieldName.length() > 0 {
                string firstChar = fieldName.substring(0, 1).toLowerAscii();
                fieldName = firstChar + fieldName.substring(1);
            }

            // Extract simple type name from fully qualified type
            string simpleTypeName = extractSimpleTypeName(method.returnType);

            RequestFieldInfo fieldInfo = {
                name: fieldName,
                typeName: simpleTypeName,
                fullType: method.returnType,
                isRequired: false
            };

            // Attach method-level javadoc/description if present
            if method.description != () {
                fieldInfo.description = method.description;
            }

            requestFields.push(fieldInfo);
        }
    }

    return requestFields;
}

# Extract response fields from a Response/Result class
#
# + responseClass - The Response class to analyze
# + return - List of response field information
public function extractResponseFields(ClassInfo responseClass) returns RequestFieldInfo[] {
    // Reuse the same approach as request extraction: methods with no parameters
    RequestFieldInfo[] responseFields = [];

    foreach MethodInfo method in responseClass.methods {
        if method.parameters.length() == 0 && method.returnType != "void" &&
           method.name != "toString" && method.name != "hashCode" &&
           method.name != "equals" && method.name != "getClass" {

            if shouldFilterField(method.name, method.returnType) {
                continue;
            }

            string fieldName = method.name;
            if fieldName.length() > 0 {
                string firstChar = fieldName.substring(0, 1).toLowerAscii();
                fieldName = firstChar + fieldName.substring(1);
            }

            string simpleTypeName = extractSimpleTypeName(method.returnType);

            RequestFieldInfo fieldInfo = {
                name: fieldName,
                typeName: simpleTypeName,
                fullType: method.returnType,
                isRequired: false
            };

            // Attach method-level javadoc/description if present
            if method.description != () {
                fieldInfo.description = method.description;
            }

            responseFields.push(fieldInfo);
        }
    }

    return responseFields;
}

# Check if a field should be filtered out (builders, utility methods, SDK internals, etc.)
#
# + fieldName - Name of the field/method
# + fieldType - Type of the field/return type
# + return - true if field should be filtered out
function shouldFilterField(string fieldName, string fieldType) returns boolean {
    // Filter Builder types
    if fieldType.endsWith("$Builder") || fieldType.endsWith(".Builder") {
        return true;
    }
    
    // Filter specific utility methods and SDK-internal fields
    string[] filteredNames = [
        "toBuilder",
        "builder",
        "serializableBuilderClass",
        "sdkFields",
        "sdkFieldNameToField"
    ];
    
    foreach string name in filteredNames {
        if fieldName == name {
            return true;
        }
    }
    
    // Filter fields that start with "sdk" (SDK-internal fields)
    if fieldName.startsWith("sdk") {
        return true;
    }
    
    // Filter has* checker methods (hasAttributes, hasTags, etc.)
    if fieldName.startsWith("has") && fieldName.length() > 3 {
        string afterHas = fieldName.substring(3, 4);
        // Check if the 4th character is uppercase (e.g., hasAttributes)
        if afterHas == afterHas.toUpperAscii() {
            return true;
        }
    }
    
    // Filter java.lang.Class type
    if fieldType == "java.lang.Class" {
        return true;
    }
    
    // Filter types containing SdkField (SDK-internal metadata)
    if fieldType.includes("SdkField") {
        return true;
    }
    
    // Filter types containing SdkBytes-related internal fields
    if fieldType.includes("software.amazon.awssdk.core.") && !fieldType.includes("SdkBytes") {
        // Allow SdkBytes but filter other SDK core types
        return true;
    }
    
    return false;
}

# Extract simple type name from fully qualified name
#
# + fullTypeName - Fully qualified type name
# + return - Simple type name (last component)
function extractSimpleTypeName(string fullTypeName) returns string {
    if fullTypeName == "" {
        return "";
    }
    
    // Handle generic types - extract the base type before the angle bracket
    string baseType = fullTypeName;
    int? angleBracket = fullTypeName.indexOf("<");
    if angleBracket is int && angleBracket >= 0 {
        baseType = fullTypeName.substring(0, angleBracket);
    }
    
    int? lastDot = baseType.lastIndexOf(".");
    if lastDot is int && lastDot >= 0 {
        return baseType.substring(lastDot + 1);
    }
    return baseType;
}

# Extract generic type parameter from a parameterized type (e.g., List<String> -> String)
#
# + fullTypeName - Fully qualified type name with generics
# + return - The generic type parameter, or null if not a generic type
public function extractGenericTypeParameter(string fullTypeName) returns string? {
    if fullTypeName == "" {
        return ();
    }
    
    // Look for angle brackets indicating generic types
    int? openBracket = fullTypeName.indexOf("<");
    int? closeBracket = fullTypeName.lastIndexOf(">");
    
    if openBracket is int && closeBracket is int && openBracket < closeBracket {
        string genericPart = fullTypeName.substring(openBracket + 1, closeBracket);
        
        // For Map types like Map<K, V>, extract the value type (second parameter)
        if genericPart.includes(",") {
            string[] parts = regex:split(genericPart, ",");
            if parts.length() >= 2 {
                // Return the value type (second type parameter), trimmed
                return parts[1].trim();
            }
        }
        
        // For single parameter generics like List<T> or Collection<T>
        return genericPart.trim();
    }
    
    return ();
}

# Check if a type is a collection type (List, Set, Collection, Map, etc.)
#
# + typeName - Simple or full type name
# + return - true if the type is a collection type
public function isCollectionType(string typeName) returns boolean {
    string lower = typeName.toLowerAscii();
    string[] collectionTypes = ["list", "set", "collection", "map", "arraylist", "hashset", "hashmap", "linkedlist", "treeset", "treemap"];
    foreach string ct in collectionTypes {
        if lower.includes(ct) {
            return true;
        }
    }
    return false;
}

# Enhance parameters with resolved request class information
#
# + parameters - Original parameters
# + allClasses - All classes for type resolution
# + methodName - Method name for heuristics
# + return - Enhanced parameters with field information
public function extractEnhancedParameters(ParameterInfo[] parameters, ClassInfo[] allClasses, string methodName)
    returns ParameterInfo[] {
    ParameterInfo[] enhancedParams = [];
    foreach ParameterInfo param in parameters {
        ParameterInfo enhancedParam = param;
        ClassInfo? resolved = resolveRequestClassFromParameter(param, allClasses, methodName);
        if resolved is ClassInfo {
            RequestFieldInfo[] requestFields = extractRequestFields(resolved);
            // Merge with any native-provided requestFields present on the param (preserve descriptions)
            RequestFieldInfo[] merged = [];
            // Build a lookup from provided param.requestFields for quick description fallback
            map<string> providedDesc = {};
            if param.requestFields is RequestFieldInfo[] {
                RequestFieldInfo[] provided = <RequestFieldInfo[]> param.requestFields;
                foreach RequestFieldInfo pf in provided {
                    if pf.description != () {
                        providedDesc[pf.name] = <string> pf.description;
                    }
                }
            }

            foreach RequestFieldInfo rf in requestFields {
                RequestFieldInfo copy = rf;
                if (copy.description == () && providedDesc.hasKey(copy.name)) {
                    copy.description = providedDesc[copy.name];
                }
                merged.push(copy);
            }

            // If the resolved extraction returned nothing, fall back to the provided fields
            if merged.length() == 0 && param.requestFields is RequestFieldInfo[] {
                RequestFieldInfo[] provided2 = <RequestFieldInfo[]> param.requestFields;
                if provided2.length() > 0 {
                    merged = provided2;
                }
            }

            enhancedParam = {
                name: param.name,
                typeName: param.typeName,
                requestFields: merged
            };
        }
        enhancedParams.push(enhancedParam);
    }
    return enhancedParams;
}

# Check if a type is a simple/primitive type
#
# + typeName - Type name to check
# + return - True if simple type
public function isSimpleType(string typeName) returns boolean {
    return typeName == "int" || typeName == "long" || typeName == "boolean" ||
           typeName == "String" || typeName == "double" || typeName == "float" ||
           typeName == "byte" || typeName == "char" || typeName == "short" ||
           typeName == "java.lang.String" || typeName == "java.lang.Object";
}

# Extract enum metadata from an enum class
#
# + enumClass - The enum ClassInfo
# + return - Enum metadata with values
public function extractEnumMetadata(ClassInfo enumClass) returns EnumMetadata {
    string[] values = [];

    // Extract enum constants from static final fields
    // Collect names in declaration order
    foreach FieldInfo fieldInfo in enumClass.fields {
        if fieldInfo.isStatic && fieldInfo.isFinal && fieldInfo.typeName == enumClass.className {
            values.push(fieldInfo.name);
        }
    }

    string? defaultName = ();
    foreach string v in values {
        if v == "DEFAULT" {
            defaultName = v;
            break;
        }
    }
    if defaultName is () {
        foreach string v in values {
            if v != "UNKNOWN_TO_SDK_VERSION" {
                defaultName = v;
                break;
            }
        }
    }
    if defaultName is () {
        if values.length() > 0 {
            defaultName = values[0];
        }
    }

    // Build output strings, marking the default entry
    string[] outValues = [];
    foreach string v in values {
        if defaultName is string && v == defaultName {
            outValues.push(v + " - default");
        } else {
            outValues.push(v);
        }
    }

    return {
        simpleName: enumClass.simpleName,
        values: outValues
    };
}


# Get descriptions for request fields from LLM (only for fields without descriptions)
#
# + fields - Request fields to get descriptions for
# + return - Fields with descriptions added
public function addRequestFieldDescriptions(RequestFieldInfo[] fields) returns RequestFieldInfo[]|error {
    if fields.length() == 0 {
        return fields;
    }
    
    // Identify fields that need descriptions (don't have javadoc descriptions)
    RequestFieldInfo[] needsDescription = [];
    int[] needsDescriptionIndices = [];
    foreach int i in 0 ..< fields.length() {
        if fields[i].description is () || fields[i].description == "" {
            needsDescription.push(fields[i]);
            needsDescriptionIndices.push(i);
        }
    }
    
    // If all fields have descriptions, return as-is
    if needsDescription.length() == 0 {
        return fields;
    }
    
    // If LLM not configured, return fields as-is
    if !isAnthropicConfigured() {
        return fields;
    }
    
    // Build field list for LLM (only fields needing descriptions)
    string fieldList = "";
    foreach int i in 0 ..< needsDescription.length() {
        RequestFieldInfo f = needsDescription[i];
        fieldList = fieldList + (i + 1).toString() + ". " + f.name + " (" + f.typeName + ")\n";
    }
    
    string systemPrompt = string `You are a Java SDK expert. Provide one-line descriptions for the given request fields.
        Each description should clearly explain what the field represents in user-friendly language.
        Return ONLY the descriptions, one per line, in the same order as the input fields.
        Do not include field names or numbers, just pure descriptions.`;
    
    string userPrompt = string `Provide one-line descriptions for these request fields:\n\n" + fieldList
        "\nDescriptions (one per line, in same order):`;
    
    json|error response = callAnthropicAPI(check getAnthropicConfig(), systemPrompt, userPrompt);
    
    if response is json {
        string responseText = extractResponseText(response).trim();
        if responseText != "" {
            string[] descriptions = regex:split(responseText, "\n");
            descriptions = descriptions.map(d => d.trim()).filter(d => d.length() > 0);
            
            // Apply LLM descriptions only to fields that needed them
            RequestFieldInfo[] result = fields.clone();
            foreach int i in 0 ..< needsDescriptionIndices.length() {
                if i < descriptions.length() {
                    int fieldIndex = needsDescriptionIndices[i];
                    result[fieldIndex].description = descriptions[i];
                }
            }
            return result;
        }
    }
    
    // Return fields without descriptions if LLM call fails
    return fields;
}
