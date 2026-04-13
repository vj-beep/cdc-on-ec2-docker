#!/usr/bin/env python3
"""
Deploy all CDC connectors via Confluent Connect REST API.

Substitutes environment variables in connector JSON configs and
deploys to Connect workers via REST API.

Usage:
    source .env
    python3 connectors/deploy-all-connectors.py

Or as a standalone script:
    python3 connectors/deploy-all-connectors.py

Environment variables are read from:
    1. Current shell environment (preferred)
    2. .env file in parent directory (fallback)

Requirements:
    - curl command available
    - Connect REST API listening on localhost:8083 and localhost:8084
"""

import json
import os
import re
import sys
import subprocess
from pathlib import Path


def load_env_file(env_path):
    """Load environment variables from .env file."""
    env_vars = {}
    if not Path(env_path).exists():
        return env_vars

    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, val = line.split('=', 1)
                env_vars[key] = val
    return env_vars


def substitute_env_vars(obj, env_vars):
    """Recursively substitute ${VAR} with environment values."""
    if isinstance(obj, str):
        def replacer(match):
            var_name = match.group(1)
            if var_name not in env_vars:
                raise ValueError(f"Undefined environment variable: {var_name}")
            return env_vars[var_name]

        return re.sub(r'\$\{([^}]+)\}', replacer, obj)
    elif isinstance(obj, dict):
        return {k: substitute_env_vars(v, env_vars) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [substitute_env_vars(v, env_vars) for v in obj]
    else:
        return obj


def deploy_connector(config, port=8083):
    """Deploy connector via Connect REST API using curl."""
    name = config.get('name', 'unknown')
    url = f"http://localhost:{port}/connectors"

    # Use curl to avoid external dependencies
    cmd = [
        'curl', '-X', 'POST', url,
        '-H', 'Content-Type: application/json',
        '-d', json.dumps(config),
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

        if result.returncode != 0:
            print(f"  ❌ {name}: curl error: {result.stderr[:100]}")
            return False

        if not result.stdout:
            print(f"  ❌ {name}: no response from Connect")
            return False

        response = json.loads(result.stdout)

        # Check for errors
        if 'error' in response and 'already exists' not in result.stdout:
            print(f"  ❌ {name}: {response.get('error', '')[:80]}")
            return False

        if 'name' in response or 'error_code' not in response:
            print(f"  ✅ {name} deployed to http://localhost:{port}")
            return True
        else:
            print(f"  ⚠️  {name}: {result.stdout[:80]}")
            return True  # May have succeeded despite error in response

    except subprocess.TimeoutExpired:
        print(f"  ❌ {name}: timeout connecting to {url}")
        return False
    except json.JSONDecodeError:
        print(f"  ⚠️  {name}: non-JSON response (may have succeeded)")
        return True
    except Exception as e:
        print(f"  ❌ {name}: {str(e)}")
        return False


def main():
    """Deploy all connectors."""
    script_dir = Path(__file__).parent
    repo_dir = script_dir.parent

    # Load environment variables
    env_vars = os.environ.copy()

    # Also try to load from .env file in parent directory
    env_file = repo_dir / '.env'
    if env_file.exists():
        file_vars = load_env_file(env_file)
        # Shell environment takes precedence
        for key, val in file_vars.items():
            if key not in env_vars:
                env_vars[key] = val

    # Define connectors with their target ports
    connectors = [
        (script_dir / 'debezium-sqlserver-source.json', 8083),  # Forward
        (script_dir / 'jdbc-sink-aurora.json', 8083),           # Forward
        (script_dir / 'debezium-postgres-source.json', 8084),   # Reverse
        (script_dir / 'jdbc-sink-sqlserver.json', 8084),        # Reverse
    ]

    print("\n" + "=" * 70)
    print("🚀 DEPLOYING CDC CONNECTORS")
    print("=" * 70 + "\n")

    deployed = 0
    for config_file, port in connectors:
        if not config_file.exists():
            print(f"  ❌ Not found: {config_file}")
            continue

        with open(config_file) as f:
            config = json.load(f)

        # Substitute environment variables
        try:
            config = substitute_env_vars(config, env_vars)
        except ValueError as e:
            print(f"  ❌ {config_file.name}: {str(e)}")
            continue

        if deploy_connector(config, port):
            deployed += 1

    print(f"\n✅ Deployed {deployed}/{len(connectors)} connectors\n")

    if deployed < len(connectors):
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
