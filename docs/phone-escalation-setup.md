# Phone escalation setup (optional)

The harness can call your phone when Codex hits a genuine blocker (a real architectural decision, an unrecoverable environment problem, or an ambiguous spec), so you can step away during a long run and still get pulled back when a human is actually needed. This is entirely optional. Skip it and the harness just surfaces blockers in the Claude conversation instead.

The phone feature uses **ElevenLabs Agents** (their conversational voice agent product, formerly "Conversational AI") to place the call, with a **Twilio** phone number as the outbound line. You bring both accounts; the harness only stores the IDs and makes one API call.

## What it costs

- **ElevenLabs**: a paid plan that includes Agents + outbound calling. Check their current pricing; the free tier generally will not place outbound phone calls.
- **Twilio**: a phone number (about 1 USD per month) plus per-minute call charges. Calls here are short ("Codex is blocked, come look"), so usage cost is negligible.

## What the harness needs at the end

Four values, stored in `~/.claude/ccx-harness/config.json` under `elevenlabs`:

- `api_key` — your ElevenLabs API key
- `agent_id` — the ElevenLabs agent that will speak when you pick up
- `agent_phone_number_id` — the imported Twilio number, as ElevenLabs identifies it
- `to_number` — your cell, in E.164 format (for example `+15551234567`)

The harness calls `POST https://api.elevenlabs.io/v1/convai/twilio/outbound-call` with those. That is the entire integration.

## Step by step

### 1. ElevenLabs account + API key

1. Create an account at https://elevenlabs.io and subscribe to a plan that includes Agents + outbound calling.
2. Get your API key from the ElevenLabs dashboard (Profile / Settings, "API Keys"). Copy it; you will paste it during harness setup.

### 2. Create the alert agent

1. In the ElevenLabs dashboard, open **Agents** and create a new agent. Name it something like "Codex Alert".
2. Configure its opening behavior so the first thing it says is useful when you answer half-asleep. The harness passes a `first_message` per call (what is blocked, what to do), but give the agent a short, calm system prompt: it is a build-alert agent, it states who is calling and what is blocked, it keeps it under a few sentences, no jargon.
3. Note the **agent_id**. You can find it in the agent's page/URL, or list all agents via the API: `GET https://api.elevenlabs.io/v1/convai/agents` with header `xi-api-key: <your key>`.

### 3. Twilio account + a number

1. Create an account at https://twilio.com.
2. From the Twilio Console, copy your **Account SID** and **Auth Token**.
3. Get a phone number: either **buy** a Twilio number (works for both inbound and outbound) or **verify a caller ID** (works for outbound only, which is all the harness needs). Either is fine.

### 4. Connect the Twilio number to ElevenLabs

1. In the ElevenLabs dashboard, open the **Phone Numbers** tab and add a number.
2. Fill in: a Label, the Phone Number, your Twilio **Account SID**, and your Twilio **Auth Token**. ElevenLabs auto-detects the number's capabilities from Twilio.
3. After it imports, note the **phone number id** (the `agent_phone_number_id` the harness wants). Find it on the number's page, or list them via the API: `GET https://api.elevenlabs.io/v1/convai/phone-numbers` with header `xi-api-key: <your key>`.
4. Optional sanity check inside ElevenLabs: on the number, click **Outbound call**, pick your agent, enter your phone, and "Send Test Call". If your phone rings, the ElevenLabs + Twilio side is wired correctly.

### 5. Wire it into the harness

Run `/ccx-harness:setup` and answer "yes" to the ElevenLabs step; it will prompt for the API key, agent_id, agent_phone_number_id, and your phone number, and write them to `~/.claude/ccx-harness/config.json` (mode 600). Or edit that file by hand:

```json
"elevenlabs": {
  "enabled": true,
  "endpoint": "https://api.elevenlabs.io/v1/convai/twilio/outbound-call",
  "agent_id": "agent_...",
  "agent_phone_number_id": "phnum_...",
  "to_number": "+15551234567",
  "api_key": "sk_..."
}
```

### 6. Test from the harness

A direct test call (replace the values with yours):

```bash
curl -s -X POST https://api.elevenlabs.io/v1/convai/twilio/outbound-call \
  -H "xi-api-key: $ELEVEN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent_...",
    "agent_phone_number_id": "phnum_...",
    "to_number": "+15551234567",
    "conversation_initiation_client_data": {
      "conversation_config_override": {
        "agent": { "first_message": "Test call from ccx-harness. Setup works. You can hang up." }
      }
    }
  }'
```

A `{"success":true,...}` response and a ringing phone means you are done. After that, the orchestrator places a call on its own whenever it classifies a Codex state as a genuine blocker.

## Using a different provider

The harness is wired specifically for the ElevenLabs `/convai/twilio/outbound-call` contract. If you prefer a competitor (Vapi, Bland, Retell, a raw Twilio call, etc.), the change is localized: swap the endpoint and request body where the orchestrator constructs the call. The four-value config shape (key, agent, number, destination) maps cleanly onto most of them. Everything else in the harness is provider-agnostic.

## Skipping it entirely

Leave `elevenlabs.enabled` false (the default). Blockers then surface in the Claude conversation and, for autonomous runs, sit in `.ccx-harness/inbox/` for you to read when you check back. The phone call is a convenience for stepping away, not a requirement.
