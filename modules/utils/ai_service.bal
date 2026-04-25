import ballerina/http;
import ballerina/log;
import ballerina/os;
import ballerina/regex;

const string CLAUDE_MODEL = "claude-sonnet-4-6";

// Pricing per million tokens (USD) — Claude Sonnet 4
const decimal INPUT_PRICE_PER_MILLION = 3.0d;
const decimal OUTPUT_PRICE_PER_MILLION = 15.0d;

string cachedApiKey = "";

// Cumulative token counters across all callAI invocations
int totalInputTokens = 0;
int totalOutputTokens = 0;
int totalCallCount = 0;

# Snapshot of cumulative LLM token usage and estimated cost.
public type TokenUsage record {|
    # Total input (prompt) tokens consumed
    int inputTokens;
    # Total output (completion) tokens consumed
    int outputTokens;
    # Combined token count
    int totalTokens;
    # Number of API calls made
    int callCount;
    # Estimated cost in USD based on model pricing
    decimal estimatedCostUsd;
|};

public function initAIService(boolean quietMode = false) returns error? {
    string apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey.length() == 0 {
        return error("ANTHROPIC_API_KEY environment variable is not set");
    }
    cachedApiKey = apiKey;

    if !quietMode {
        log:printInfo("LLM service initialized successfully");
    }
}

public function callAI(string prompt) returns string|error {
    if cachedApiKey.length() == 0 {
        return error("AI model not initialized. Please call initAIService() first.");
    }
    return invokeAnthropicAPI(cachedApiKey, "", prompt, 64000);
}

public function isAIServiceInitialized() returns boolean {
    return cachedApiKey.length() > 0;
}

# Return a snapshot of cumulative token usage and estimated cost since last reset.
#
# + return - TokenUsage record with counts and USD cost estimate
public function getTokenUsage() returns TokenUsage {
    decimal inputCost = (<decimal>totalInputTokens / 1000000.0d) * INPUT_PRICE_PER_MILLION;
    decimal outputCost = (<decimal>totalOutputTokens / 1000000.0d) * OUTPUT_PRICE_PER_MILLION;
    return {
        inputTokens: totalInputTokens,
        outputTokens: totalOutputTokens,
        totalTokens: totalInputTokens + totalOutputTokens,
        callCount: totalCallCount,
        estimatedCostUsd: inputCost + outputCost
    };
}

# Reset cumulative token counters to zero.
public function resetTokenUsage() {
    totalInputTokens = 0;
    totalOutputTokens = 0;
    totalCallCount = 0;
}

# Record token usage from an external LLM call (e.g. modules with their own HTTP client).
#
# + inputTokens - Input tokens consumed by the call
# + outputTokens - Output tokens consumed by the call
public function recordTokenUsage(int inputTokens, int outputTokens) {
    totalInputTokens += inputTokens;
    totalOutputTokens += outputTokens;
    totalCallCount += 1;
}

# Extract a JSON object string from an LLM response that may be wrapped in markdown fences.
#
# + responseText - Full LLM response text
# + return - Extracted JSON object string or error
public function extractJsonFromLLMResponse(string responseText) returns string|error {
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

// Internal HTTP call — shared by callAI and future extensions.
function invokeAnthropicAPI(string apiKey, string systemPrompt, string userPrompt,
        int maxTokens) returns string|error {
    http:Client anthropicClient = check new ("https://api.anthropic.com", {
        timeout: 400
    });

    map<json> bodyMap = {
        "model": CLAUDE_MODEL,
        "max_tokens": maxTokens,
        "messages": [{"role": "user", "content": userPrompt}]
    };

    if systemPrompt.length() > 0 {
        bodyMap["system"] = systemPrompt;
    }

    map<string> headers = {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
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

    // Accumulate token usage from the response
    json|error usageJson = responseBody.usage;
    if usageJson is json {
        json|error inputJson = usageJson.input_tokens;
        json|error outputJson = usageJson.output_tokens;
        if inputJson is json {
            int|error inputCount = int:fromString(inputJson.toString());
            if inputCount is int {
                totalInputTokens += inputCount;
            }
        }
        if outputJson is json {
            int|error outputCount = int:fromString(outputJson.toString());
            if outputCount is int {
                totalOutputTokens += outputCount;
            }
        }
    }
    totalCallCount += 1;

    // Walk content blocks from the end to return the last text block
    json|error contentArray = responseBody.content;
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

    return error("AI response content is empty.");
}
