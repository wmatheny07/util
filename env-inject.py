import os
import sys
from dotenv import load_dotenv

def inject_env(template_path: str, output_path: str, env_file: str):
    """
    Reads a template config file and injects environment variables
    of the form ${VAR_NAME} using values from env_file + current environment.
    """
    load_dotenv(dotenv_path=env_file, override=True)

    with open(template_path, "r") as f:
        content = f.read()

    # Replace placeholders ${ENV}
    for key, value in os.environ.items():
        if value is None:
            continue
        placeholder = f"${{{key}}}"  # e.g. ${HOST_IP}
        if placeholder in content:
            content = content.replace(placeholder, str(value))

    with open(output_path, "w") as f:
        f.write(content)

    print(f"Injected config written to {output_path}")

def usage():
    print("Usage: env-inject.py <template_file_path> <output_file_path> [env_file_path]")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        usage()
        sys.exit(2)

    template_file = sys.argv[1]
    output_file = sys.argv[2]
    env_file = sys.argv[3] if len(sys.argv) >= 4 else "/opt/config/.env.prod"

    inject_env(template_file, output_file, env_file)