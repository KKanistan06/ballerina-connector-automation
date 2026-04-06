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
import ballerina/regex;

# Generate an IntermediateRepresentation by sending the raw metadata JSON
# to the LLM and parsing its structured IR JSON response.
#
# + metadataPath - Path to the sdk_analyzer metadata JSON file
# + config - Generator configuration
# + return - IntermediateRepresentation or error
public function generateIRFromMetadata(string metadataPath, GeneratorConfig config)
        returns IntermediateRepresentation|error {

    // Read raw metadata JSON text
    string metadataJson = check io:fileReadString(metadataPath);

    // Retrieve Anthropic configuration
    AnthropicConfig anthropicCfg = check getAnthropicConfig(
        config.maxTokens,
        config.enableExtendedThinking,
        config.thinkingBudgetTokens
    );

    string systemPrompt = getIRGenerationSystemPrompt();
    string userPrompt = getIRGenerationUserPrompt(metadataJson);

    // Call LLM
    json llmResponse = check callAnthropicAPI(anthropicCfg, systemPrompt, userPrompt);
    string responseText = extractResponseText(llmResponse);

    // Extract JSON from response text
    string irJsonStr = check extractJsonFromResponse(responseText);

    // Validate JSON is complete before parsing
    if !isCompleteJson(irJsonStr) {
        // Save the incomplete JSON for debugging
        string debugPath = string `${config.outputDir}/incomplete-ir-response.json`;
        return error(string `IR JSON is incomplete or truncated (${irJsonStr.length()} chars). ` +
                     string `The LLM response may have exceeded token limits. ` +
                     string `Try increasing maxTokens in GeneratorConfig or reducing the SDK complexity. ` +
                     string `Incomplete JSON saved to: ${debugPath}`);
    }

    // Parse JSON string to IR – provide a useful snippet on failure
    json|error irJsonResult = irJsonStr.fromJsonString();
    if irJsonResult is error {
        int snippetLen = irJsonStr.length() < 300 ? irJsonStr.length() : 300;
        int tailStart = irJsonStr.length() > 200 ? irJsonStr.length() - 200 : 0;
        string head = irJsonStr.substring(0, snippetLen);
        string tail = irJsonStr.substring(tailStart);
        // Save the malformed JSON for debugging
        string debugPath = string `${config.outputDir}/malformed-ir-response.json`;
        return error(string `IR JSON parse failed (total ${irJsonStr.length()} chars). ` +
                     string `HEAD: ${head} ... TAIL: ${tail}. ` +
                     string `Malformed JSON saved to: ${debugPath}`, irJsonResult);
    }
    json irJson = irJsonResult;
    IntermediateRepresentation|error irResult = irJson.cloneWithType(IntermediateRepresentation);
    if irResult is error {
        return error("IR JSON structure does not match IntermediateRepresentation schema: " +
                     irResult.message(), irResult);
    }
    IntermediateRepresentation ir = irResult;

    // Post-process: ensure every referenced type is defined in structures/enums/collections
    return ensureIRCompleteness(ir);
}

# Extract the base type name from a Ballerina type expression.
# Strips map<X> → X and X[] → X wrappers.
#
# + typeName - Full type string
# + return - Base type name
function extractBaseType(string typeName) returns string {
    string t = typeName.trim();
    if t.startsWith("map<") && t.endsWith(">") {
        return t.substring(4, t.length() - 1).trim();
    }
    if t.endsWith("[]") {
        return t.substring(0, t.length() - 2).trim();
    }
    return t;
}

# Return true if the type name is a Ballerina built-in that needs no definition.
#
# + typeName - Base type name (no wrappers)
# + return - true when the type is a built-in
function isBuiltinBallerina(string typeName) returns boolean {
    string[] builtins = [
        "string", "int", "float", "boolean", "byte", "decimal",
        "anydata", "json", "xml", "byte[]", "anydata[]",
        "map<anydata>", "map<string>", "map<json>", "()", "void", ""
    ];
    foreach string b in builtins {
        if typeName == b {
            return true;
        }
    }
    return false;
}

# Collect all base type names referenced anywhere in the IR (fields, params, returns).
#
# + ir - IntermediateRepresentation to scan
# + return - Set of all base type names referenced
function collectReferencedTypes(IntermediateRepresentation ir) returns map<boolean> {
    map<boolean> referenced = {};

    // Connection fields
    foreach IRField f in ir.connectionFields {
        referenced[extractBaseType(f.'type)] = true;
    }

    // Function parameters and returns
    foreach IRFunction fn in ir.functions {
        foreach IRParameter p in fn.parameters {
            referenced[extractBaseType(p.'type)] = true;
            string? ref = p.referenceType;
            if ref is string {
                referenced[ref] = true;
            }
        }
        string retBase = extractBaseType(fn.'return.'type);
        referenced[retBase] = true;
        string? retRef = fn.'return.referenceType;
        if retRef is string {
            referenced[retRef] = true;
        }
    }

    // Structure fields (one level deep)
    foreach IRStructure s in ir.structures {
        foreach IRField f in s.fields {
            referenced[extractBaseType(f.'type)] = true;
        }
    }

    return referenced;
}

# Determine whether a type name looks like an enum based on common suffixes.
#
# + typeName - Type name to test
# + return - true if the name has a typical enum suffix
function looksLikeEnum(string typeName) returns boolean {
    string[] enumSuffixes = [
        "Mode", "Type", "Status", "Class", "Algorithm", "ACL",
        "Payer", "Encryption", "Protocol", "Access", "Permission",
        "Tier", "Action", "State", "Policy", "Direction"
    ];
    foreach string suffix in enumSuffixes {
        if typeName.endsWith(suffix) {
            return true;
        }
    }
    return false;
}

# Ensure the IR is complete: every type referenced must be defined.
# Adds empty stub entries for any missing types.
#
# + ir - Raw IR from LLM
# + return - IR with stubs added for every undefined type
function ensureIRCompleteness(IntermediateRepresentation ir) returns IntermediateRepresentation {
    // Build a set of already-defined type names
    map<boolean> defined = {};
    foreach IRStructure s in ir.structures {
        defined[s.name] = true;
    }
    foreach IREnum e in ir.enums {
        defined[e.name] = true;
    }
    foreach IRCollection c in ir.collections {
        defined[c.name] = true;
    }

    // Collect referenced types
    map<boolean> referenced = collectReferencedTypes(ir);

    // Find gaps and build stub lists
    IRStructure[] extraStructures = [];
    IREnum[] extraEnums = [];

    foreach string typeName in referenced.keys() {
        if isBuiltinBallerina(typeName) || defined.hasKey(typeName) {
            continue;
        }
        // Add stub
        if looksLikeEnum(typeName) {
            extraEnums.push({name: typeName, kind: "ENUM", nativeType: "string", values: []});
        } else {
            extraStructures.push({name: typeName, kind: "STRUCTURE", fields: []});
        }
        defined[typeName] = true; // prevent duplicates
    }

    if extraStructures.length() == 0 && extraEnums.length() == 0 {
        return ir;
    }

    IRStructure[] allStructures = [...ir.structures, ...extraStructures];
    IREnum[] allEnums = [...ir.enums, ...extraEnums];
    return {
        sdkName: ir.sdkName,
        version: ir.version,
        clientName: ir.clientName,
        clientDescription: ir.clientDescription,
        connectionFields: ir.connectionFields,
        functions: ir.functions,
        structures: allStructures,
        enums: allEnums,
        collections: ir.collections
    };
}

# Extract a JSON object string from LLM response text.
# Handles responses wrapped in ```json ... ``` fences or returned as raw JSON.
#
# + responseText - Full text response from the LLM
# + return - JSON object string or error
function extractJsonFromResponse(string responseText) returns string|error {
    // Try ```json ... ``` fenced block
    if responseText.includes("```json") {
        string[] parts = regex:split(responseText, "```json");
        if parts.length() >= 2 {
            string block = parts[1];
            int? closingIdx = block.indexOf("```");
            if closingIdx is int && closingIdx > 0 {
                return block.substring(0, closingIdx).trim();
            }
            return block.trim();
        }
    }

    // Try generic ``` ... ``` fenced block
    if responseText.includes("```") {
        string[] parts = regex:split(responseText, "```");
        if parts.length() >= 3 {
            string block = parts[1].trim();
            // Strip optional language tag on first line (e.g. "json\n")
            int? newline = block.indexOf("\n");
            if newline is int && newline < 10 {
                string tag = block.substring(0, newline).trim();
                if tag == "json" || tag == "" {
                    block = block.substring(newline + 1);
                }
            }
            return block.trim();
        }
    }

    // Try raw JSON – locate the outermost { ... } object
    int? startIdx = responseText.indexOf("{");
    int? endIdx = responseText.lastIndexOf("}");
    if startIdx is int && endIdx is int && endIdx > startIdx {
        return responseText.substring(startIdx, endIdx + 1).trim();
    }

    return error("Could not extract JSON from LLM response. " +
                 "Expected a raw JSON object or a ```json fenced block.");
}

# Check if a JSON string is syntactically complete (balanced braces/brackets).
#
# + jsonStr - JSON string to validate
# + return - true if JSON appears complete
function isCompleteJson(string jsonStr) returns boolean {
    int braceCount = 0;
    int bracketCount = 0;
    boolean inString = false;
    boolean escaped = false;

    int i = 0;
    while i < jsonStr.length() {
        string char = jsonStr.substring(i, i + 1);
        
        if escaped {
            escaped = false;
            i += 1;
            continue;
        }

        if char == "\\" {
            escaped = true;
            i += 1;
            continue;
        }

        if char == "\"" {
            inString = !inString;
            i += 1;
            continue;
        }

        if !inString {
            if char == "{" {
                braceCount += 1;
            } else if char == "}" {
                braceCount -= 1;
            } else if char == "[" {
                bracketCount += 1;
            } else if char == "]" {
                bracketCount -= 1;
            }
        }

        i += 1;
    }

    // JSON is complete if all braces and brackets are balanced and we're not in a string
    return braceCount == 0 && bracketCount == 0 && !inString;
}
