#!/usr/bin/env python3
"""
Simple healthcheck script for Docker.
Returns exit code 0 if healthy, 1 if unhealthy.
"""

import sys
import urllib.request
import os

def main():
    port = os.getenv('API_PORT', '8071')
    url = f'http://localhost:{port}/health'

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            if response.status == 200:
                print("Health check passed")
                sys.exit(0)
            else:
                print(f"Health check failed: HTTP {response.status}")
                sys.exit(1)
    except Exception as e:
        print(f"Health check failed: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
