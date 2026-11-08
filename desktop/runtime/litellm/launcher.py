"""Application entry points for the pinned LiteLLM distribution. No server patches."""
import os
import sys

# Keep bytecode and telemetry out of the signed app and disable remote model-map fetches.
sys.dont_write_bytecode = True
os.environ['LITELLM_LOCAL_MODEL_COST_MAP'] = 'True'
os.environ['LITELLM_TELEMETRY'] = 'False'
os.umask(0o077)

import litellm
litellm.telemetry = False

if sys.argv[1:] == ['--check']:
    from importlib.metadata import version
    import litellm.proxy.proxy_cli
    assert version('litellm') == '1.97.0'
    assert version('fastapi') == '0.136.3'
    print('LiteLLM 1.97.0 / FastAPI 0.136.3 OK', flush=True)
elif sys.argv[1:] == ['--login']:
    from litellm.llms.chatgpt.authenticator import Authenticator
    try:
        Authenticator().get_access_token()
        print('ChatGPT sign-in complete.', flush=True)
    except Exception:
        print('ChatGPT sign-in failed. Please retry.', flush=True)
        sys.exit(1)
else:
    from litellm.proxy.proxy_cli import run_server
    sys.argv += ["--telemetry", "False"]
    run_server()
