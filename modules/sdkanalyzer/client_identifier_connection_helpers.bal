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

# Check if a type name is a primitive or standard Java type
#
# + typeName - Type name to check
# + return - True if primitive or standard type, false otherwise
function isPrimitiveType(string typeName) returns boolean {
    string lower = typeName.toLowerAscii();
    return lower == "int" || lower == "long" || lower == "float" || lower == "double" ||
           lower == "boolean" || lower == "byte" || lower == "char" || lower == "short" ||
           lower == "string" || lower == "java.lang.string" || lower == "java.lang.object" ||
           lower == "void" || lower == "java.lang.integer" || lower == "java.lang.long" ||
           lower == "java.lang.boolean" || lower == "java.lang.double";
}

# Check if a type is a standard Java library type (java.*, javax.*) that doesn't need a typeReference.
#
# + typeName - Fully qualified type name to check
# + return - True if standard Java type, false otherwise
function isStandardJavaType(string typeName) returns boolean {
    return typeName.startsWith("java.") || typeName.startsWith("javax.");
}

# Find a class by name in the resolved classes, or lazily resolve from dependency JARs.
# If resolved from dependencies, the class is added to the resolvedClasses array for future lookups.
#
# + className - The class name to find
# + resolvedClasses - Mutable array of all resolved classes
# + dependencyJarPaths - Paths to dependency JARs for resolving external classes
# + return - The ClassInfo if found, otherwise ()
function findOrResolveClass(string className, ClassInfo[] resolvedClasses, string[] dependencyJarPaths) returns ClassInfo? {
    // First try to find in already-resolved classes
    ClassInfo? found = findClassByName(className, resolvedClasses);
    if found is ClassInfo {
        return found;
    }
    
    // Try to resolve from dependency JARs
    if dependencyJarPaths.length() > 0 {
        ClassInfo? resolved = resolveClassFromJars(className, dependencyJarPaths);
        if resolved is ClassInfo {
            // Add to resolved classes for future lookups
            resolvedClasses.push(resolved);
            return resolved;
        }
    }
    
    return ();
}

# Extract enum constants from an enum class
#
# + enumClass - The enum ClassInfo
# + return - List of enum constants as RequestFieldInfo
function extractEnumConstants(ClassInfo enumClass) returns RequestFieldInfo[] {
    RequestFieldInfo[] constants = [];
    
    foreach FieldInfo fld in enumClass.fields {
        // Enum constants are static final fields of the enum type itself
        if fld.isStatic && fld.isFinal {
            // Skip internal fields like $VALUES, UNKNOWN_TO_SDK_VERSION, etc.
            if fld.name.startsWith("$") || fld.name == "UNKNOWN_TO_SDK_VERSION" {
                continue;
            }
            
            RequestFieldInfo constInfo = {
                name: fld.name,
                typeName: enumClass.simpleName,
                fullType: enumClass.className,
                isRequired: false
            };
            
            // Add javadoc description if available
            if fld.javadoc != () {
                constInfo.description = fld.javadoc;
            }
            
            constants.push(constInfo);
        }
    }
    
    return constants;
}

# Build a level 1 context string for a class, used for LLM enrichment of connection fields.
#
# + cls - The ClassInfo to analyze
# + return - A string describing the class category and key methods/fields for LLM context
function buildLevel1Context(ClassInfo cls) returns string {
    string category;
    if cls.isEnum {
        category = "Enum";
    } else if cls.isInterface {
        category = "Interface";
    } else if cls.isAbstract {
        category = "AbstractClass";
    } else {
        category = "Class";
    }

    if cls.isEnum {
        string[] constants = [];
        foreach FieldInfo fld in cls.fields {
            if fld.isStatic && fld.isFinal && !fld.name.startsWith("$") &&
               fld.name != "UNKNOWN_TO_SDK_VERSION" {
                constants.push(fld.name);
                if constants.length() >= 8 {
                    break;
                }
            }
        }
        if constants.length() > 0 {
            return category + " with values: " + string:'join(", ", ...constants);
        }
        return category;
    }

    string[] methodNames = [];
    string[] skipNames = ["toString", "hashCode", "equals", "getClass", "notify",
                          "notifyAll", "wait", "clone", "finalize"];
    foreach MethodInfo m in cls.methods {
        boolean skip = false;
        foreach string s in skipNames {
            if m.name == s {
                skip = true;
                break;
            }
        }
        if !skip {
            methodNames.push(m.name);
        }
        if methodNames.length() >= 10 {
            break;
        }
    }

    if methodNames.length() > 0 {
        return category + " with methods: " + string:'join(", ", ...methodNames);
    }
    return category;
}

# Check if SDK_VERBOSE environment variable is set to enable verbose logging for connection field enrichment.
# + return - True if verbose logging is enabled, false otherwise
function isSdkVerboseEnabled() returns boolean {
    string? envVal = os:getEnv("SDK_VERBOSE");
    if envVal is string {
        string lower = envVal.toLowerAscii();
        return lower == "1" || lower == "true" || lower == "yes";
    }
    return false;
}

# Helper function to print logs related to connection field enrichment, only if verbose logging is enabled.
#
# + message - The log message to print
function printConnectionEnrichLog(string message) {
    if isSdkVerboseEnabled() {
        io:println(string `  [connection-enrich] ${message}`);
    }
}

# Enrich connection fields using LLM to determine if they are required, adjust types, and add descriptions.
#
# + fields - The array of connection fields to enrich
# + sdkPackage - The SDK package name
# + clientSimpleName - The simple name of the client
# + return - The enriched connection fields and synthetic type metadata
function enrichConnectionFieldsWithLLM(
    ConnectionFieldInfo[] fields,
    string sdkPackage,
    string clientSimpleName
) returns [ConnectionFieldInfo[], SyntheticTypeMetadata[]] {

    SyntheticTypeMetadata[] syntheticMeta = [];

    if fields.length() == 0 {
        return [fields, syntheticMeta];
    }

    if !isAnthropicConfigured() {
        printConnectionEnrichLog("LLM not configured — skipping enrichment");
        return [fields, syntheticMeta];
    }

    AnthropicConfiguration|error llmConfigResult = getAnthropicConfig();
    if llmConfigResult is error {
        printConnectionEnrichLog(string `Cannot get LLM config: ${llmConfigResult.message()}`);
        return [fields, syntheticMeta];
    }
    AnthropicConfiguration llmConfig = llmConfigResult;

    string systemPrompt = getConnectionFieldEnrichmentSystemPrompt();
    string userPrompt = getConnectionFieldEnrichmentUserPrompt(sdkPackage, clientSimpleName, fields);

    printConnectionEnrichLog(string `Enriching ${fields.length()} connection fields via LLM...`);

    json|error response = callAnthropicAPI(llmConfig, systemPrompt, userPrompt);
    if response is error {
        printConnectionEnrichLog(string `LLM call failed: ${response.message()} — using raw fields`);
        return [fields, syntheticMeta];
    }

    string responseText = extractResponseText(response).trim();
    if responseText.length() == 0 {
        printConnectionEnrichLog("Empty LLM response — using raw fields");
        return [fields, syntheticMeta];
    }

    // Strip markdown code fences
    string jsonText = responseText;
    if jsonText.startsWith("```json") {
        jsonText = jsonText.substring(7);
    } else if jsonText.startsWith("```") {
        jsonText = jsonText.substring(3);
    }
    if jsonText.endsWith("```") {
        jsonText = jsonText.substring(0, jsonText.length() - 3);
    }
    jsonText = jsonText.trim();

    // Extract outermost JSON array
    int? arrayStart = jsonText.indexOf("[");
    int? arrayEnd = jsonText.lastIndexOf("]");
    if arrayStart is int && arrayEnd is int && arrayEnd > arrayStart {
        jsonText = jsonText.substring(arrayStart, arrayEnd + 1);
    }

    json|error parsed = jsonText.fromJsonString();
    if parsed is error {
        printConnectionEnrichLog(string `JSON parse error: ${parsed.message()} — using raw fields`);
        return [fields, syntheticMeta];
    }

    if !(parsed is json[]) {
        printConnectionEnrichLog("LLM response was not a JSON array — using raw fields");
        return [fields, syntheticMeta];
    }

    json[] llmEntries = <json[]>parsed;

    // Build lookup: field name → LLM entry
    map<map<json>> enrichmentMap = {};
    foreach json entry in llmEntries {
        if entry is map<json> {
            json nameVal = entry["name"];
            if nameVal is string {
                enrichmentMap[nameVal] = entry;
            }
        }
    }

    int enrichedCount = 0;
    ConnectionFieldInfo[] result = [];

    foreach ConnectionFieldInfo f in fields {
        map<json>? enrichment = enrichmentMap[f.name];

        if enrichment is () {
            result.push(f);
            continue;
        }

        map<json> e = enrichment;

        string? newDesc = f.description;
        json descVal = e["description"];
        if descVal is string && descVal.trim().length() > 0 {
            newDesc = descVal.trim();
        }

        boolean newRequired = f.isRequired;
        json reqVal = e["isRequired"];
        if reqVal is boolean {
            newRequired = reqVal;
        }

        string newTypeName = f.typeName;
        string? newEnumRef = f.enumReference;
        string? newTypeRef = f.typeReference;

        json btVal = e["ballerinaType"];
        string ballerinaType = "";
        if btVal is string {
            ballerinaType = btVal.trim().toLowerAscii();
        }

        if ballerinaType == "enum" {
            if newTypeRef is string {
                newEnumRef = newTypeRef;
                newTypeRef = ();
            }

        } else if ballerinaType == "string" || ballerinaType == "uri" {
            newTypeRef = ();
            newTypeName = "string";

        } else if ballerinaType == "int" {
            newTypeRef = ();
            newTypeName = "int";

        } else if ballerinaType == "boolean" {
            newTypeRef = ();
            newTypeName = "boolean";
        }

        if ballerinaType == "enum" && newEnumRef is string {
            string enumRefKey = <string>newEnumRef;
            string[] syntheticEnumValues = [];
            json enumValsJson = e["enumValues"];
            if enumValsJson is json[] {
                foreach json ev in enumValsJson {
                    if ev is string {
                        syntheticEnumValues.push(ev);
                    }
                }
            }
            SyntheticTypeMetadata stm = {
                fullType: enumRefKey,
                simpleName: f.typeName,
                ballerinaType: "enum",
                enumValues: syntheticEnumValues,
                subFields: []
            };
            // De-duplicate synthetic entries
            boolean alreadyAdded = false;
            foreach SyntheticTypeMetadata existing in syntheticMeta {
                if existing.fullType == enumRefKey {
                    alreadyAdded = true;
                    break;
                }
            }
            if !alreadyAdded {
                syntheticMeta.push(stm);
            }

        } else if (ballerinaType == "record" || ballerinaType == "object") &&
                   newTypeRef is string {
            string typeRefKey = <string>newTypeRef;
            RequestFieldInfo[] syntheticSubFields = [];
            json subFieldsJson = e["subFields"];
            if subFieldsJson is json[] {
                foreach json sf in subFieldsJson {
                    if sf is map<json> {
                        json sfName = sf["name"];
                        json sfType = sf["type"];
                        json sfDesc = sf["description"];
                        json sfReq = sf["isRequired"];
                        if sfName is string && sfType is string {
                            RequestFieldInfo rfi = {
                                name: sfName,
                                typeName: sfType,
                                fullType: sfType,
                                isRequired: sfReq is boolean ? sfReq : false,
                                description: sfDesc is string ? sfDesc : ()
                            };
                            syntheticSubFields.push(rfi);
                        }
                    }
                }
            }
            SyntheticTypeMetadata stm = {
                fullType: typeRefKey,
                simpleName: f.typeName,
                ballerinaType: ballerinaType,
                enumValues: [],
                subFields: syntheticSubFields
            };
            boolean alreadyAdded = false;
            foreach SyntheticTypeMetadata existing in syntheticMeta {
                if existing.fullType == typeRefKey {
                    alreadyAdded = true;
                    break;
                }
            }
            if !alreadyAdded {
                syntheticMeta.push(stm);
            }
        }

        ConnectionFieldInfo enriched = {
            name: f.name,
            typeName: newTypeName,
            fullType: f.fullType,
            isRequired: newRequired,
            enumReference: newEnumRef,
            memberReference: f.memberReference,
            typeReference: newTypeRef,
            description: newDesc,
            level1Context: f.level1Context
        };

        result.push(enriched);
        enrichedCount += 1;
    }

    printConnectionEnrichLog(string `Enriched ${enrichedCount}/${fields.length()} fields; ` +
               string `${syntheticMeta.length()} synthetic type entries generated`);
    return [result, syntheticMeta];
}
