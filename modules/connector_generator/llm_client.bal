import ballerina/http;
import ballerina/os;
import ballerina/regex;

import wso2/connector_automation.utils;

# Check whether the Anthropic API key is configured.
# + return - true if the ANTHROPIC_API_KEY env variable is set
public function isAnthropicConfigured() returns boolean {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    return apiKey is string && apiKey.length() > 0;
}

# Retrieve Anthropic configuration for connector generation.
#
# + maxTokens - Maximum response tokens
# + enableExtendedThinking - Whether to enable extended thinking mode
# + thinkingBudgetTokens - Token budget for thinking mode
# + return - Anthropic configuration or error
public function getAnthropicConfig(int maxTokens, boolean enableExtendedThinking,
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

# Call Anthropic Messages API for connector generation.
#
# + config - Anthropic configuration
# + systemPrompt - System prompt text
# + userPrompt - User prompt text
# + return - Raw JSON response or error
public function callAnthropicAPI(AnthropicConfig config, string systemPrompt,
        string userPrompt) returns json|error {
    http:Client anthropicClient = check new ("https://api.anthropic.com", {
        timeout: 240000
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

    if config.enableExtendedThinking {
        bodyMap["thinking"] = {
            "type": "enabled",
            "budget_tokens": config.thinkingBudgetTokens
        };
    }

    map<string> headers = {
        "Content-Type": "application/json",
        "x-api-key": config.apiKey,
        "anthropic-version": "2023-06-01"
    };

    http:Response response = check anthropicClient->post("/v1/messages", bodyMap, headers);

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

    json|error stopReason = responseBody.stop_reason;
    if stopReason is json && stopReason.toString() == "max_tokens" {
        return error(string `LLM response was truncated due to max_tokens limit (${config.maxTokens}). ` +
            "Increase maxTokens in ConnectorGeneratorConfig.");
    }

    return responseBody;
}

# Extract text content from Anthropic response.
#
# + response - Raw Anthropic response JSON
# + return - Best text payload block content
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
                return castResult is string ? castResult : textField.toString();
            }
            idx -= 1;
        }
    }
    return response.toString();
}

# Extract JSON object string from LLM response text.
#
# + responseText - Full LLM response text
# + return - Extracted JSON object string or error
public function extractJsonFromResponse(string responseText) returns string|error {
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

    if responseText.includes("```") {
        string[] parts = regex:split(responseText, "```");
        if parts.length() >= 3 {
            string block = parts[1].trim();
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

    int? startIdx = responseText.indexOf("{");
    int? endIdx = responseText.lastIndexOf("}");
    if startIdx is int && endIdx is int && endIdx > startIdx {
        return responseText.substring(startIdx, endIdx + 1).trim();
    }

    return error("Could not extract JSON from LLM response.");
}
