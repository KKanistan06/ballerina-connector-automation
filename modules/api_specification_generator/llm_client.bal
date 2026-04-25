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

import ballerina/http;
import ballerina/os;

import wso2/connector_automation.utils;

# Check whether the Anthropic API key is configured.
#
# + return - true if the ANTHROPIC_API_KEY env variable is set
public function isAnthropicConfigured() returns boolean {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    return apiKey is string && apiKey.length() > 0;
}

# Retrieve Anthropic configuration from environment with custom token budget.
#
# + maxTokens - Maximum response tokens
# + enableExtendedThinking - Whether to enable extended thinking
# + thinkingBudgetTokens - Budget for extended thinking
# + return - AnthropicConfig or error
function getAnthropicConfig(int maxTokens, boolean enableExtendedThinking,
        int thinkingBudgetTokens) returns AnthropicConfig|error {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey is () || apiKey.length() == 0 {
        return error("ANTHROPIC_API_KEY environment variable not set");
    }

    return {
        apiKey: apiKey,
        model: "claude-sonnet-4-6",
        maxTokens: maxTokens,
        temperature: enableExtendedThinking ? 1.0d : 0.0d,
        enableExtendedThinking: enableExtendedThinking,
        thinkingBudgetTokens: thinkingBudgetTokens
    };
}

# Call the Anthropic Messages API.
#
# + config - Anthropic configuration
# + systemPrompt - System prompt
# + userPrompt - User prompt
# + return - Full JSON response or error
function callAnthropicAPI(AnthropicConfig config, string systemPrompt, string userPrompt) returns json|error {
    http:Client anthropicClient = check new ("https://api.anthropic.com", {
        timeout: 120000
    });

    map<json> bodyMap = {
        "model": config.model,
        "max_tokens": config.maxTokens,
        "temperature": config.temperature,
        "messages": [
            {
                "role": "user",
                "content": userPrompt
            }
        ],
        "system": systemPrompt
    };

    // Extended thinking for deep code generation
    if config.enableExtendedThinking {
        bodyMap["thinking"] = {
            "type": "enabled",
            "budget_tokens": config.thinkingBudgetTokens
        };
    }

    json requestBody = bodyMap;

    map<string> headers = {
        "Content-Type": "application/json",
        "x-api-key": config.apiKey,
        "anthropic-version": "2023-06-01"
    };

    http:Response response = check anthropicClient->post("/v1/messages", requestBody, headers);

    if response.statusCode != 200 {
        string|error responseText = response.getTextPayload();
        if responseText is string {
            return error(string `Anthropic API error: ${response.statusCode} - ${responseText}`);
        }
        return error(string `Anthropic API error: ${response.statusCode}`);
    }

    json responseBody = check response.getJsonPayload();

    json|error usageJson = responseBody.usage;
    if usageJson is json {
        int inputCount = 0;
        int outputCount = 0;
        json|error inputJson = usageJson.input_tokens;
        json|error outputJson = usageJson.output_tokens;
        if inputJson is json {
            int|error parsed = int:fromString(inputJson.toString());
            if parsed is int { inputCount = parsed; }
        }
        if outputJson is json {
            int|error parsed = int:fromString(outputJson.toString());
            if parsed is int { outputCount = parsed; }
        }
        utils:recordTokenUsage(inputCount, outputCount);
    }

    // Check if the response was truncated due to token limits
    json|error stopReason = responseBody.stop_reason;
    if stopReason is json && stopReason.toString() == "max_tokens" {
        return error(string `LLM response was truncated due to max_tokens limit (${config.maxTokens}). ` +
                    "Increase maxTokens in GeneratorConfig or reduce SDK complexity.");
    }

    return responseBody;
}

# Extract the text content from an Anthropic API response.
#
# + response - Raw JSON response from the Anthropic API
# + return - Extracted text content
public function extractResponseText(json response) returns string {
    json|error contentArray = response.content;
    if contentArray is json && contentArray is json[] {
        json[] contentList = <json[]>contentArray;
        int idx = contentList.length() - 1;
        while idx >= 0 {
            json block = contentList[idx];
            json|error blockType = block.'type;
            json|error textField = block.text;
            if blockType is json && blockType.toString() == "text" && textField is json {
                string|error castResult = textField.ensureType(string);
                string text = castResult is string ? castResult : textField.toString();
                return text;
            }
            idx -= 1;
        }
    }

    return response.toString();
}
