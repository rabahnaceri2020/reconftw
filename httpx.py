#!/usr/bin/env python3
"""
Headless Browser HTTP Response Capture Script
Captures full HTTP request/response using headless browser for all domains in data/*.all files
"""

import os
import sys
import glob
import json
from pathlib import Path
from urllib.parse import urlparse

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("[!] Playwright not installed!")
    print("[*] Install with: pip3 install playwright && playwright install chromium")
    sys.exit(1)


DATA_DIR = "/root/reconftw/data"
OUTPUT_DIR = "/opt/response"


def save_http_response(domain, url, responses_list):
    """Save HTTP request/response(s) to file"""

    # Create domain-specific directory
    parsed = urlparse(url)
    subdomain = parsed.netloc or domain
    output_path = Path(OUTPUT_DIR) / domain
    output_path.mkdir(parents=True, exist_ok=True)

    # Create output file: /tmp/response/{domain}/{subdomain}
    output_file = output_path / subdomain

    with open(output_file, 'w', encoding='utf-8') as f:
        # Write all responses (first response + redirect if any)
        for idx, response_info in enumerate(responses_list, 1):
            response_data = response_info['response_data']
            response_body = response_info['response_body']
            response_url = response_info['url']

            if idx > 1:
                f.write("\n\n\n")
                f.write("=" * 60 + "\n")
                f.write(f"REDIRECT {idx - 1}\n")
                f.write("=" * 60 + "\n\n\n")

            # Write response status and headers
            f.write(f"HTTP/1.1 {response_data['status']} {response_data['statusText']}\n\n")
            for key, value in response_data.get('headers', {}).items():
                f.write(f"{key}: {value}\n")
            f.write("\n")

            # Write response body
            if response_body:
                f.write(response_body)
            f.write("\n\n")
            f.write(response_url)

    return output_file


def capture_with_browser(url, domain, timeout=6000):
    """Capture HTTP traffic using headless browser"""

    # Check if response already exists
    from urllib.parse import urlparse
    parsed = urlparse(url)
    subdomain = parsed.netloc or domain
    output_file = Path(OUTPUT_DIR) / domain / subdomain

    if output_file.exists():
        print(f"  [⏭] Already exists, skipping: {output_file}")
        return True

    requests = []
    responses = {}

    with sync_playwright() as p:
        try:
            # Launch headless browser
            browser = p.chromium.launch(
                headless=True,
                args=['--ignore-certificate-errors', '--ignore-certificate-errors-spki-list']
            )
            context = browser.new_context(
                user_agent='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                ignore_https_errors=True,
                accept_downloads=False
            )
            page = context.new_page()
            # Set default timeout for all operations
            page.set_default_timeout(timeout)

            # Capture network traffic
            def handle_request(request):
                try:
                    post_data = request.post_data
                except:
                    post_data = None  # Binary or non-UTF-8 data

                requests.append({
                    'url': request.url,
                    'method': request.method,
                    'headers': request.headers,
                    'post_data': post_data
                })

            def handle_response(response):
                responses[response.url] = {
                    'status': response.status,
                    'statusText': response.status_text,
                    'headers': response.headers,
                    'url': response.url
                }

            # Visit the URL and capture responses (first + one redirect)
            print(f"  [*] Visiting: {url}")

            # Track all responses in order with their bodies
            captured_responses = []

            def capture_response(response):
                # Capture response with its body
                try:
                    body = response.text()
                except:
                    body = ""

                captured_responses.append({
                    'url': response.url,
                    'status': response.status,
                    'headers': response.headers,
                    'body': body,
                    'request': response.request
                })

            page.on('response', capture_response)

            try:
                # Use domcontentloaded to get responses
                page.goto(url, timeout=timeout, wait_until='domcontentloaded')
            except Exception as e:
                # Allow some common errors
                pass

            # Filter and process captured responses
            responses_to_save = []

            # Add status text mapping
            status_texts = {
                200: 'OK', 201: 'Created', 204: 'No Content',
                301: 'Moved Permanently', 302: 'Found', 303: 'See Other',
                304: 'Not Modified', 307: 'Temporary Redirect', 308: 'Permanent Redirect',
                400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found',
                500: 'Internal Server Error', 502: 'Bad Gateway', 503: 'Service Unavailable'
            }

            # Find the first response matching our URL
            url_normalized = url.rstrip('/')
            first_idx = None
            for idx, resp in enumerate(captured_responses):
                resp_url_normalized = resp['url'].rstrip('/')
                if resp_url_normalized == url_normalized:
                    first_idx = idx
                    break

            if first_idx is not None:
                # Get first response
                first_resp = captured_responses[first_idx]

                responses_to_save.append({
                    'url': first_resp['url'],
                    'response_data': {
                        'status': first_resp['status'],
                        'statusText': status_texts.get(first_resp['status'], 'Unknown'),
                        'headers': first_resp['headers'],
                        'url': first_resp['url']
                    },
                    'response_body': first_resp['body']
                })

                # Check if it's a redirect (3xx) and follow once
                if 300 <= first_resp['status'] < 400:
                    redirect_url = first_resp['headers'].get('location', '')
                    if redirect_url:
                        # Handle relative redirects
                        if not redirect_url.startswith('http'):
                            from urllib.parse import urljoin
                            redirect_url = urljoin(first_resp['url'], redirect_url)

                        print(f"  [→] Following redirect to: {redirect_url}")

                        # Find the redirect response by checking the request chain
                        # We look for a response whose request was redirected from our first response's request
                        redirect_resp = None
                        for resp in captured_responses:
                            req = resp['request']
                            if req.redirected_from and req.redirected_from.url == first_resp['request'].url:
                                redirect_resp = resp
                                break

                        # Fallback: if not found via chain, try URL matching (for safety)
                        if not redirect_resp:
                            redirect_url_normalized = redirect_url.rstrip('/')
                            for resp in captured_responses:
                                resp_url_normalized = resp['url'].rstrip('/')
                                if resp_url_normalized == redirect_url_normalized:
                                    redirect_resp = resp
                                    break

                        if redirect_resp:
                            responses_to_save.append({
                                'url': redirect_resp['url'],
                                'response_data': {
                                    'status': redirect_resp['status'],
                                    'statusText': status_texts.get(redirect_resp['status'], 'Unknown'),
                                    'headers': redirect_resp['headers'],
                                    'url': redirect_resp['url']
                                },
                                'response_body': redirect_resp['body']
                            })

            # Check if we got any responses
            if responses_to_save:
                output_file = save_http_response(domain, url, responses_to_save)
                print(f"  [✓] Saved {len(responses_to_save)} response(s) to: {output_file}")
                return True

            return False

        except Exception as e:
            error_msg = str(e).split('\n')[0]  # Get first line of error
            print(f"  [✗] Error visiting {url}: {error_msg}")

            # Try to save whatever response we got before the error
            if responses:
                try:
                    # Get the first response (usually the main page)
                    main_url = list(responses.keys())[0] if responses else url
                    response_data = responses.get(main_url, {
                        'status': 0,
                        'statusText': 'Error',
                        'headers': {},
                        'url': url
                    })

                    # Try to get page content
                    try:
                        body = page.content()
                    except:
                        body = f"[Error: {error_msg}]"

                    responses_list = [{
                        'url': url,
                        'response_data': response_data,
                        'response_body': body
                    }]

                    output_file = save_http_response(domain, url, responses_list)
                    print(f"  [~] Partial response saved to: {output_file}")
                    return True
                except Exception as save_error:
                    print(f"  [!] Could not save partial response: {save_error}")

            return False

        finally:
            try:
                browser.close()
            except:
                pass

    return False


def process_domain_file(file_path):
    """Process a single .all file"""

    filename = os.path.basename(file_path)
    domain = filename.replace('.txt.all', '')

    print(f"\n[*] Processing: {filename}")
    print(f"[*] Domain: {domain}")

    # Read domains from file
    with open(file_path, 'r') as f:
        domains = [line.strip() for line in f if line.strip()]

    print(f"[*] Found {len(domains)} domains to process")

    success_count = 0
    for i, subdomain in enumerate(domains, 1):
        # Try HTTPS first, then HTTP
        for protocol in ['https', 'http']:
            url = f"{protocol}://{subdomain}"
            print(f"[{i}/{len(domains)}] {url}")

            if capture_with_browser(url, domain):
                success_count += 1
                break  # Success, move to next domain

    print(f"[✓] Completed {domain}: {success_count}/{len(domains)} successful")
    return success_count


def main():
    """Main function"""

    # Create output directory
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Find all .all files
    pattern = os.path.join(DATA_DIR, "*.all")
    all_files = glob.glob(pattern)

    if not all_files:
        print(f"[!] No .all files found in {DATA_DIR}")
        sys.exit(1)

    print(f"[*] Found {len(all_files)} .all files to process")
    print(f"[*] Output directory: {OUTPUT_DIR}")
    print("=" * 60)

    total_success = 0
    for file_path in all_files:
        success = process_domain_file(file_path)
        total_success += success

    print("\n" + "=" * 60)
    print(f"[✓] All files processed successfully!")
    print(f"[*] Total captures: {total_success}")
    print(f"[*] Results saved in: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()

