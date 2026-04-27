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

# Get Anthropic configuration from environment
# + return - Anthropic configuration or error
function getAnthropicConfig() returns AnthropicConfiguration|error {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey is () {
        return error("ANTHROPIC_API_KEY environment variable not set");
    }

    return {
        apiKey: apiKey,
        model: "claude-sonnet-4-6",
        maxTokens: 5000,
        temperature: 0,
        enableExtendedThinking: false
    };
}

# Make API call to Anthropic Claude
# + config - Anthropic configuration
# + systemPrompt - System prompt
# + userPrompt - User prompt  
# + return - API response or error
function callAnthropicAPI(AnthropicConfiguration config, string systemPrompt, string userPrompt) returns json|error {
    http:Client anthropicClient = check new ("https://api.anthropic.com", {
        timeout: 30
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

    // Add extended thinking if enabled
    if config.enableExtendedThinking {
        bodyMap["thinking"] = {
            "type": "enabled",
            "budget_tokens": 5000
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

    return responseBody;
}
