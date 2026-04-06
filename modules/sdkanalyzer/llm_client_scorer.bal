// Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
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

# Calculate LLM-based client score for a class using LLM's own knowledge.
#
# + cls - Class to score
# + allClasses - All classes for context
# + return - LLM client score based on LLM analysis
public function calculateLLMClientScore(ClassInfo cls, ClassInfo[] allClasses) returns LLMClientScore|error {
    // Enforce LLM-only scoring: call the Anthropic LLM and return its score.
    if !isAnthropicConfigured() {
        return error("Anthropic LLM not configured: LLM-only scoring required");
    }

    LLMClientScore|error llmScore = callLLMForClientScoring(cls, allClasses);
    if llmScore is LLMClientScore {
        return llmScore;
    }

    return llmScore; // propagate error
}

# Call LLM to score a class as potential root client.
#
# + cls - Class to evaluate
# + allClasses - All classes in JAR
# + return - Score from LLM or error
function callLLMForClientScoring(ClassInfo cls, ClassInfo[] allClasses) returns LLMClientScore|error {
    string systemPrompt = getClientScoringSystemPrompt();
    string classInfo = formatClassInfoForLLM(cls);
    string userPrompt = getClientScoringUserPrompt(classInfo);

    json|error response = callAnthropicAPI(check getAnthropicConfig(), systemPrompt, userPrompt);
    
    if response is error {
        return response;
    }
    
        // Extract text from Anthropic API response structure: response.content[0].text
        string responseText = "";
        
        // response.content is a json array of content blocks
        json|error contentArray = response.content;
        if contentArray is json && contentArray is json[] {
            json[] contentList = <json[]>contentArray;
            if contentList.length() > 0 {
                json firstContent = contentList[0];
                // Access text field from the first content block
                json|error textField = firstContent.text;
                if textField is json && textField is string {
                    responseText = textField.toString();
                } else if textField is json {
                    responseText = textField.toString();
                }
            }
        }
        
        if responseText == "" {
            // Last resort fallback
            responseText = response.toString();
        }
        
        // Try to parse "SCORE:XX" format
        string[] matches = regex:split(responseText, "\\|");
        if matches.length() > 0 {
            string scoreStr = matches[0];
            if scoreStr.includes("SCORE:") {
                string[] parts = regex:split(scoreStr, ":");
                if parts.length() > 1 {
                    int|error parsedScore = int:fromString(parts[1].trim());
                    if parsedScore is int {
                        decimal score = <decimal>parsedScore;
                        if score > 100.0d {
                            score = 100.0d;
                        } else if score < 0.0d {
                            score = 0.0d;
                        }
                        
                        string reason = matches.length() > 1 ? matches[1] : "LLM analysis";
                        
                        return {
                            publicApiScore: score * 0.3d,
                            operationCoverage: score * 0.25d,
                            hasRequestResponseTypes: score * 0.20d,
                            stabilityScore: score * 0.15d,
                            exampleUsageScore: score * 0.10d,
                            totalScore: score,
                            breakdown: string `LLM Analysis:\n${reason}`
                        };
                    }
                }
            }
        }
    
    return error("Failed to parse LLM response for client scoring");
}
