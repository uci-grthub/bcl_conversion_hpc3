# Delivery rules (delivery side / workflow B).
#
# These rules need a Nextcloud instance and a mail relay, so they run on the
# dragen server, not on HPC3.  They are deliberately NOT included by the
# conversion Snakefile: a rule that runs in "disabled" mode still produces its
# output files, and after an rsync those stubs look up-to-date, which is why the
# combined workflow had to be hand-touched on the delivery host.
#
# Every value these rules need about the run comes from handoff/ (see
# src/handoff.smk).  Nothing here parses metadata or SampleSheets.

rule project_link:
    input:
        # The handoff fragment, not the raw output directory: its existence is the
        # conversion workflow's statement that this project's FASTQs, md5sums and
        # plots are final.  Sharing a directory that is still being written would
        # publish a link to a partial delivery.
        fragment = "handoff/projects/{config_id}---{project}.yaml"
    output:
        log = "logs/{config_id}/project_link_{config_id}---{project}.log",
        yaml_file = "logs/{config_id}/project_links_{config_id}---{project}.yaml"
    benchmark:
        "benchmarks/project_link_{config_id}---{project}.bench"
    wildcard_constraints:
        # Relaxed to accept any lane-prefixed config with additional underscore-separated tokens
        config_id = "[^/]+",
        project = ".+"
    resources:
        serial_operation=1
    params:
        work_dir = os.getcwd(),
        # order_id and group were resolved once, on the conversion side, from the
        # metadata workbook.  Re-deriving them here from the folder name is how the
        # two halves used to disagree about which order a duplicate project belongs to.
        order_id = lambda wildcards: handoff_entry(wildcards.config_id, wildcards.project)["order_id"],
        group = lambda wildcards: handoff_entry(wildcards.config_id, wildcards.project)["group"]
    run:
        import traceback
        import subprocess
        import sys
        from pathlib import Path
        import time
        import urllib.parse
        import re
        import os
        import shlex
        import glob as _glob

        config_id = wildcards.config_id
        project = wildcards.project
        order_id = params.order_id
        group = params.group
        fastq_dir = f"output/{config_id}/{project}"
        log_file = output.log
        yaml_file = output.yaml_file

        if not str(order_id).strip():
            msg = (
                f"Missing order_id for project link generation "
                f"(config_id={config_id}, project={project}, group={group}). "
                "Check metadata order-id mapping for this project/lane."
            )
            Path(log_file).write_text(msg + "\n")
            raise RuntimeError(msg)

        os.makedirs(os.path.dirname(log_file), exist_ok=True)

        yaml_data = {project: {config_id: {}}}

        # Helper: Extract Browser URL
        def extract_share_url(xml_text):
            if not xml_text: return None
            match = re.search(r'<url>(.*?)</url>', xml_text)
            return match.group(1) if match else None

        # Helper: Extract Token (This is your WebDAV Username)
        def extract_share_token(xml_text):
            if not xml_text: return None
            match = re.search(r'<token>(.*?)</token>', xml_text)
            return match.group(1) if match else None

        def extract_share_owner(xml_text):
            if not xml_text: return None
            m = re.search(r'<uid_owner>(.*?)</uid_owner>', xml_text)
            if m:
                return m.group(1)
            # fallback: sometimes owner is in <id> or <owner>
            m2 = re.search(r'<owner>(.*?)</owner>', xml_text)
            if m2:
                return m2.group(1)
            return None

        def extract_share_id(xml_text):
            if not xml_text: return None
            m = re.search(r'<id>(\d+)</id>', xml_text)
            return m.group(1) if m else None

        def extract_internal_path(xml_text):
            if not xml_text: return None
            m = re.search(r'<path>(.*?)</path>', xml_text)
            if m:
                return m.group(1)
            # fallback: sometimes in <folder>
            m2 = re.search(r'<folder>(.*?)</folder>', xml_text)
            if m2:
                return m2.group(1)
            return None

        def extract_share_id(xml_text):
            if not xml_text: return None
            m = re.search(r'<id>(\d+)</id>', xml_text)
            return m.group(1) if m else None

        # Capture executed commands for logging
        executed_cmds = []

        def fetch_existing_share(path, log_handle):
            encoded_path = urllib.parse.quote(path, safe="/")
            cmd = [
                'curl', '-s', '-X', 'GET',
                '-u', f'{NEXTCLOUD_USER}:{NEXTCLOUD_PASSWORD}',
                '-H', 'OCS-APIRequest: true',
                f'{NEXTCLOUD_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares?path={encoded_path}&reshares=true'
            ]
            executed_cmds.append(cmd)
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            return result.stdout

        try:
            if os.path.isdir(fastq_dir):
                abs_path = os.path.abspath(fastq_dir)
                nc_path = f"/{NEXTCLOUD_DIR_NAME}/" + abs_path.split(f"/{NEXTCLOUD_DIR_PATH}/", 1)[1] if f"/{NEXTCLOUD_DIR_PATH}/" in abs_path else abs_path
                
                max_retries = 30  # Retry up to 30 times with exponential backoff
                retry_count = 0
                share_url = None
                share_token = None
                share_id_num = None
                share_xml = None
                rate_limited = False
                last_error = None
                
                while retry_count < max_retries and not share_url:
                    retry_count += 1
                    wait_time = min(3 * (2 ** (retry_count - 1)), 60)
                    if rate_limited: time.sleep(10)
                    
                    try:
                        cmd = [
                            'curl', '-s', '-w', '\nHTTP_CODE:%{http_code}',
                            '-X', 'POST',
                            '-u', f'{NEXTCLOUD_USER}:{NEXTCLOUD_PASSWORD}',
                            '-H', 'OCS-APIRequest: true',
                            '-d', f'path={nc_path}',
                            '-d', 'shareType=3', # 3 = Public Link
                            f'{NEXTCLOUD_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares'
                        ]
                        executed_cmds.append(cmd)
                        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                        
                        stdout_split = result.stdout.split('\n')
                        http_code = next((l.split(':')[1] for l in stdout_split if l.startswith('HTTP_CODE:')), None)
                        share_xml = '\n'.join([l for l in stdout_split if not l.startswith('HTTP_CODE:')])

                        if http_code == '429':
                            rate_limited = True
                            last_error = f"Rate limited (HTTP {http_code})"
                        elif http_code == '200' or http_code == '201':
                            # Success - extract data from response
                            share_url = extract_share_url(share_xml)
                            share_token = extract_share_token(share_xml)
                            share_id_num = extract_share_id(share_xml)
                            if share_url and share_token:
                                try:
                                    owner = extract_share_owner(share_xml)
                                    internal_path = extract_internal_path(share_xml)
                                except Exception:
                                    owner = None
                                    internal_path = None
                                share_owner = owner
                                share_internal_path = internal_path
                                break
                            else:
                                last_error = f"Valid response but could not extract URL/token (HTTP {http_code})"
                        elif http_code == '400' or http_code == '403':
                            # 403 usually means "already exists" - try GET to fetch existing share
                            share_xml = fetch_existing_share(nc_path, None)
                            share_url = extract_share_url(share_xml)
                            share_token = extract_share_token(share_xml)
                            share_id_num = extract_share_id(share_xml)
                            if share_url and share_token:
                                try:
                                    owner = extract_share_owner(share_xml)
                                    internal_path = extract_internal_path(share_xml)
                                except Exception:
                                    owner = None
                                    internal_path = None
                                share_owner = owner
                                share_internal_path = internal_path
                                break
                            else:
                                last_error = f"Share may exist but could not fetch via GET (HTTP {http_code})"
                        else:
                            last_error = f"HTTP {http_code}: {share_xml[:100] if share_xml else 'No response'}"

                        if retry_count < max_retries and not share_url:
                            time.sleep(wait_time)

                    except subprocess.TimeoutExpired:
                        last_error = "Request timed out (30 seconds)"
                        if retry_count < max_retries:
                            time.sleep(wait_time)
                    except Exception as e:
                        last_error = f"Exception: {str(e)}"
                        if retry_count < max_retries:
                            time.sleep(wait_time)

                # --- RESTORE PRIOR TOKEN FROM EXISTING LOGS ---
                # Nextcloud re-shares get a fresh token each run, which breaks links already
                # sent to users. If a prior successful share for this nc_path recorded a token,
                # push it back so the public URL stays stable across pipeline re-runs.
                if share_url and share_token and share_id_num:
                    old_token = None
                    for lp in sorted(_glob.glob("logs/**/project_link_*.log", recursive=True)):
                        if os.path.abspath(lp) == os.path.abspath(log_file):
                            continue
                        try:
                            content = Path(lp).read_text()
                            if f"NC_PATH: {nc_path}" in content and "Status: SUCCESS" in content:
                                m = re.search(r'^WebDAV Token: (\S+)', content, re.MULTILINE)
                                if m:
                                    old_token = m.group(1)
                                    break
                        except Exception:
                            pass
                    if old_token and old_token != share_token:
                        put_cmd = [
                            sys.executable, "scripts/test_nextcloud_token.py",
                            "--share-id", share_id_num,
                            "--token", old_token
                        ]
                        executed_cmds.append(put_cmd)
                        put_result = subprocess.run(put_cmd, capture_output=True, text=True, timeout=30)
                        m_token = re.search(r'New Token\s*:\s*(\S+)', put_result.stdout)
                        m_url = re.search(r'New URL\s*:\s*(\S+)', put_result.stdout)
                        if m_token:
                            share_token = m_token.group(1)
                        if m_url:
                            share_url = m_url.group(1)

                # --- LOGGING WEB DAV CREDENTIALS AND EXECUTED COMMANDS ---
                with open(log_file, 'w') as f:
                    f.write(f"Project: {project}\n")
                    f.write(f"Config ID: {config_id}\n")
                    # Always write Order ID and Group (needed for report generation)
                    f.write(f"Order ID: {order_id}\n")
                    f.write(f"Group: {group}\n")
                    # Write the Nextcloud path we attempted to share (for rescan parsing)
                    try:
                        f.write(f"NC_PATH: {nc_path}\n")
                    except Exception:
                        pass
                    if share_url and share_token:
                        f.write(f"Status: SUCCESS\n")
                        f.write(f"Browser URL: {share_url}\n")
                        f.write(f"WebDAV URL: {NEXTCLOUD_URL}/public.php/dav/\n")
                        f.write(f"WebDAV Token: {share_token}\n")
                        # If available, record Nextcloud owner and internal storage path
                        try:
                            if share_owner:
                                f.write(f"NC_OWNER: {share_owner}\n")
                            if share_internal_path:
                                f.write(f"NC_INTERNAL_PATH: {share_internal_path}\n")
                        except Exception:
                            pass
                        # Populate individual project yaml
                        yaml_data[project][config_id][order_id] = {"link": share_url, "group": group}
                    else:
                        f.write(f"Status: FAILED\n")
                        f.write(f"Reason: {last_error}\n")
                        f.write(f"Retries: {retry_count}/{max_retries}\n")

                    # Record the actual commands executed (quoted for copy/paste)
                    if executed_cmds:
                        f.write("\nCommands executed:\n")
                        for c in executed_cmds:
                            try:
                                quoted = shlex.join(c)
                            except Exception:
                                quoted = ' '.join(shlex.quote(p) for p in c)
                            f.write(quoted + "\n")
            else:
                Path(log_file).write_text(f"Directory {fastq_dir} not found.")

        except Exception as e:
            Path(log_file).write_text(f"Error: {str(e)}\n{traceback.format_exc()}")

        Path(log_file).touch(exist_ok=True)

        # Write individual project yaml (empty dict if sharing failed)
        import yaml as _yaml
        with open(yaml_file, 'w') as yf:
            _yaml.dump(yaml_data, yf, default_flow_style=False)

rule flexbar_project_link:
    """Create a Nextcloud share for the flexbar output directory and record the link."""
    input:
        fragment = "handoff/flexbar/{config_id}.yaml"
    output:
        link_log  = "logs/{config_id}/flexbar_project_link_{config_id}.log",
        yaml_file = "logs/{config_id}/flexbar_project_links_{config_id}.yaml"
    benchmark:
        "benchmarks/flexbar_project_link_{config_id}.bench"
    wildcard_constraints:
        config_id = "[^/]+"
    resources:
        serial_operation = 1
    params:
        work_dir  = os.getcwd(),
        order_id  = lambda wildcards: flexbar_handoff_entry(wildcards.config_id)["order_id"],
        project   = lambda wildcards: flexbar_handoff_entry(wildcards.config_id)["project"],
    run:
        import traceback, subprocess, time, urllib.parse, re, os, shlex
        from pathlib import Path
        import yaml as _yaml

        config_id = wildcards.config_id
        order_id  = params.order_id
        project   = params.project
        fastq_dir = f"output/{config_id}/flexbar"
        log_file  = output.link_log
        yaml_file = output.yaml_file

        if not str(order_id).strip():
            msg = (
                f"Missing order_id for flexbar project link generation "
                f"(config_id={config_id}, project={project}). "
                "Check metadata order-id mapping for this config."
            )
            Path(log_file).write_text(msg + "\n")
            raise RuntimeError(msg)

        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        yaml_data = {project: {config_id: {}}}

        def extract_share_url(xml_text):
            if not xml_text: return None
            m = re.search(r'<url>(.*?)</url>', xml_text)
            return m.group(1) if m else None

        def extract_share_token(xml_text):
            if not xml_text: return None
            m = re.search(r'<token>(.*?)</token>', xml_text)
            return m.group(1) if m else None

        def extract_share_owner(xml_text):
            if not xml_text: return None
            for pattern in [r'<uid_owner>(.*?)</uid_owner>', r'<owner>(.*?)</owner>']:
                m = re.search(pattern, xml_text)
                if m: return m.group(1)
            return None

        def extract_internal_path(xml_text):
            if not xml_text: return None
            for pattern in [r'<path>(.*?)</path>', r'<folder>(.*?)</folder>']:
                m = re.search(pattern, xml_text)
                if m: return m.group(1)
            return None

        def fetch_existing_share(path):
            encoded = urllib.parse.quote(path, safe="/")
            cmd = ['curl', '-s', '-X', 'GET',
                   '-u', f'{NEXTCLOUD_USER}:{NEXTCLOUD_PASSWORD}',
                   '-H', 'OCS-APIRequest: true',
                   f'{NEXTCLOUD_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares?path={encoded}&reshares=true']
            return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout

        executed_cmds = []
        try:
            if os.path.isdir(fastq_dir):
                abs_path = os.path.abspath(fastq_dir)
                nc_path = f"/{NEXTCLOUD_DIR_NAME}/" + abs_path.split(f"/{NEXTCLOUD_DIR_PATH}/", 1)[1] \
                          if f"/{NEXTCLOUD_DIR_PATH}/" in abs_path else abs_path

                max_retries, retry_count = 30, 0
                share_url = share_token = share_owner = share_internal_path = None
                rate_limited, last_error = False, None

                while retry_count < max_retries and not share_url:
                    retry_count += 1
                    wait_time = min(3 * (2 ** (retry_count - 1)), 60)
                    if rate_limited: time.sleep(10)
                    try:
                        cmd = ['curl', '-s', '-w', '\nHTTP_CODE:%{http_code}',
                               '-X', 'POST',
                               '-u', f'{NEXTCLOUD_USER}:{NEXTCLOUD_PASSWORD}',
                               '-H', 'OCS-APIRequest: true',
                               '-d', f'path={nc_path}', '-d', 'shareType=3',
                               f'{NEXTCLOUD_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares']
                        executed_cmds.append(cmd)
                        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                        lines = result.stdout.split('\n')
                        http_code = next((l.split(':')[1] for l in lines if l.startswith('HTTP_CODE:')), None)
                        share_xml = '\n'.join(l for l in lines if not l.startswith('HTTP_CODE:'))
                        if http_code == '429':
                            rate_limited = True; last_error = f"Rate limited (HTTP 429)"
                        elif http_code in ('200', '201'):
                            share_url   = extract_share_url(share_xml)
                            share_token = extract_share_token(share_xml)
                            if share_url and share_token:
                                share_owner         = extract_share_owner(share_xml)
                                share_internal_path = extract_internal_path(share_xml)
                                break
                            else:
                                last_error = f"Valid response but could not extract URL/token (HTTP {http_code})"
                        elif http_code in ('400', '403'):
                            share_xml   = fetch_existing_share(nc_path)
                            share_url   = extract_share_url(share_xml)
                            share_token = extract_share_token(share_xml)
                            if share_url and share_token:
                                share_owner         = extract_share_owner(share_xml)
                                share_internal_path = extract_internal_path(share_xml)
                                break
                            else:
                                last_error = f"Share may exist but could not fetch via GET (HTTP {http_code})"
                        else:
                            last_error = f"HTTP {http_code}: {share_xml[:100] if share_xml else 'No response'}"
                        if retry_count < max_retries and not share_url:
                            time.sleep(wait_time)
                    except subprocess.TimeoutExpired:
                        last_error = "Request timed out (30 seconds)"
                        if retry_count < max_retries: time.sleep(wait_time)
                    except Exception as e:
                        last_error = f"Exception: {str(e)}"
                        if retry_count < max_retries: time.sleep(wait_time)

                with open(log_file, 'w') as f:
                    f.write(f"Project: {project}\nConfig ID: {config_id}\nOrder ID: {order_id}\n")
                    try: f.write(f"NC_PATH: {nc_path}\n")
                    except Exception: pass
                    if share_url and share_token:
                        f.write(f"Status: SUCCESS\nBrowser URL: {share_url}\n")
                        f.write(f"WebDAV URL: {NEXTCLOUD_URL}/public.php/dav/\nWebDAV Token: {share_token}\n")
                        if share_owner:         f.write(f"NC_OWNER: {share_owner}\n")
                        if share_internal_path: f.write(f"NC_INTERNAL_PATH: {share_internal_path}\n")
                        yaml_data[project][config_id][order_id] = {"link": share_url, "group": "flexbar"}
                    else:
                        f.write(f"Status: FAILED\nReason: {last_error}\nRetries: {retry_count}/{max_retries}\n")
                    if executed_cmds:
                        f.write("\nCommands executed:\n")
                        for c in executed_cmds:
                            try:    f.write(shlex.join(c) + "\n")
                            except: f.write(' '.join(shlex.quote(p) for p in c) + "\n")
            else:
                Path(log_file).write_text(f"Directory {fastq_dir} not found.")
        except Exception as e:
            Path(log_file).write_text(f"Error: {str(e)}\n{traceback.format_exc()}")

        Path(log_file).touch(exist_ok=True)
        with open(yaml_file, 'w') as yf:
            _yaml.dump(yaml_data, yf, default_flow_style=False)


rule rescan_nextcloud:
    input:
        "logs/{config_id}/project_link_{config_id}---{project}.log"
    output:
        touch("logs/{config_id}/nextcloud_scan_{config_id}---{project}.done")
    log:
        "logs/{config_id}/rescan_nextcloud_{config_id}_{project}.log"
    benchmark:
        "benchmarks/rescan_nextcloud_{config_id}_{project}.bench"
    wildcard_constraints:
        # Relaxed to accept any lane-prefixed config with additional underscore-separated tokens
        config_id = "[^/]+",
        project = ".+"
    params:
        nc_path = lambda wildcards: f"/{NEXTCLOUD_DIR_NAME}/{LIBRARY}/output/{wildcards.config_id}/{wildcards.project}",
        nc_user = NEXTCLOUD_USER,
        ssh_host = NEXTCLOUD_SSH_HOST
    shell:
        """
        # Read NC_PATH from the project_link log (written by project_link rule) and use that for scanning.
        nc_log={input}
        nc_path=$(grep '^NC_PATH:' "$nc_log" | sed 's/^NC_PATH: //') || true
        nc_owner=$(grep '^NC_OWNER:' "$nc_log" | sed 's/^NC_OWNER: //') || true
        nc_internal=$(grep '^NC_INTERNAL_PATH:' "$nc_log" | sed 's/^NC_INTERNAL_PATH: //') || true

        # Prefer owner+internal_path if available (construct users/<owner>/files/<internal>)
        if [ -n "$nc_owner" ] && [ -n "$nc_internal" ]; then
            # strip leading slashes from internal
            internal=$(echo "$nc_internal" | sed 's@^/*@@')
            # OCC expects "<user>/files/<path>", not "users/<user>/files/<path>".
            # Normalize if internal path already includes a user/files prefix.
            internal=$(echo "$internal" | sed "s@^users/${{nc_owner}}/files/@@")
            internal=$(echo "$internal" | sed 's@^files/@@')
            occ_path="$nc_owner/files/$internal"
        elif [ -n "$nc_path" ]; then
            # project_link failed before it could record NC_OWNER/NC_INTERNAL_PATH,
            # so only NC_PATH is available. NC_PATH is relative to the API account's
            # files root (same convention as the WebDAV URL), *not* a host filesystem
            # path -- passing it to occ verbatim makes occ read its first segment as a
            # username ("Unknown user 1 dragenshare"). Prefix it to form a valid
            # "<user>/files/<path>" argument. Note this names the Nextcloud data owner,
            # unrelated to the SSH login used to reach the host.
            rel=$(echo "$nc_path" | sed 's@^/*@@')
            rel=$(echo "$rel" | sed "s@^users/{params.nc_user}/files/@@")
            rel=$(echo "$rel" | sed "s@^{params.nc_user}/files/@@")
            rel=$(echo "$rel" | sed 's@^files/@@')
            occ_path="{params.nc_user}/files/$rel"
        else
            echo "NC path information not found in $nc_log" > {log}
            exit 1
        fi

        ssh {params.ssh_host} "docker exec --user www-data nextcloud-aio-nextcloud php occ files:scan --path='$occ_path'" > {log} 2>&1

        # OCC can report malformed --path usage while still returning quickly.
        if grep -q "Unknown user" {log}; then
            echo "ERROR: files:scan used an invalid user path: $occ_path" >> {log}
            exit 1
        fi
        """



rule verify_project_links:
    input:
        project_link_log = "logs/{config_id}/project_link_{config_id}---{project}.log",
        scan_done = "logs/{config_id}/nextcloud_scan_{config_id}---{project}.done"
    output:
        report = "logs/{config_id}/verify_project_link_{config_id}---{project}.txt"
    log:
        "logs/{config_id}/verify_project_link_{config_id}---{project}.log"
    benchmark:
        "benchmarks/verify_project_link_{config_id}---{project}.bench"
    wildcard_constraints:
        # Relaxed to accept any lane-prefixed config with additional underscore-separated tokens
        config_id = "[^/]+",
        project = ".+"
    run:
        import subprocess
        import re
        import os

        config_id = wildcards.config_id
        project = wildcards.project
        local_dir = f"output/{config_id}/{project}"
        
        # Read the project_link log to extract the share URL
        share_url = None
        with open(input.project_link_log, 'r') as f:
            content = f.read()
            match = re.search(r'Share link: (https://.*)', content)
            if match:
                share_url = match.group(1).strip()
        
        report = []
        report.append(f"Project Link Verification Report")
        report.append(f"Config ID: {config_id}")
        report.append(f"Project: {project}")
        report.append(f"Local Directory: {local_dir}")
        report.append(f"Share URL: {share_url if share_url else 'NOT FOUND'}")
        report.append("")
        
        # Get local fastq.gz files
        local_fastqs = []
        if os.path.isdir(local_dir):
            try:
                local_fastqs = sorted([f for f in os.listdir(local_dir) if f.endswith('.fastq.gz')])
            except Exception as e:
                report.append(f"ERROR reading local directory: {e}")
        else:
            report.append(f"Local directory does not exist: {local_dir}")
        
        report.append(f"Local FASTQ files ({len(local_fastqs)}):")
        for f in local_fastqs:
            report.append(f"  - {f}")
        report.append("")
        
        # Query Nextcloud share for files if URL is available
        remote_fastqs = []
        if share_url:
            try:
                # Extract the share token from the URL
                # URL format: https://precision.biochem.uci.edu/s/SHARETOKEN
                match = re.search(r'/s/([a-zA-Z0-9]+)', share_url)
                if match:
                    share_token = match.group(1)
                    
                    # Query the WebDAV API to list files in the share
                    # Using curl to query the share with basic auth
                    cmd = [
                        'curl', '-s',
                        '-u', f'{NEXTCLOUD_USER}:{NEXTCLOUD_PASSWORD}',
                        '-X', 'PROPFIND',
                        '-H', 'Depth: 1',
                        f'{NEXTCLOUD_URL}/remote.php/dav/files/{NEXTCLOUD_USER}/{NEXTCLOUD_DIR_NAME}/{LIBRARY}/output/{config_id}/{project}/'
                    ]
                    
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                    
                    # Parse XML response to extract filenames
                    if result.stdout:
                        # Extract hrefs from the PROPFIND response
                        hrefs = re.findall(r'<d:href>(.*?)</d:href>', result.stdout)
                        for href in hrefs:
                            # Extract just the filename from the full path
                            filename = href.split('/')[-1]
                            if filename and filename.endswith('.fastq.gz'):
                                remote_fastqs.append(filename)
                        remote_fastqs = sorted(set(remote_fastqs))
            except Exception as e:
                report.append(f"ERROR querying Nextcloud: {e}")
        
        if remote_fastqs:
            report.append(f"Remote FASTQ files ({len(remote_fastqs)}):")
            for f in remote_fastqs:
                report.append(f"  - {f}")
            report.append("")
        
        # Compare files
        local_set = set(local_fastqs)
        remote_set = set(remote_fastqs)
        
        report.append("VERIFICATION RESULTS:")
        if local_set == remote_set:
            report.append("✓ SUCCESS: Local and remote files match perfectly")
            report.append(f"  Total files: {len(local_set)}")
        else:
            report.append("✗ MISMATCH: Local and remote files differ")
            
            missing_remote = local_set - remote_set
            if missing_remote:
                report.append(f"\n  Files in local but NOT in remote ({len(missing_remote)}):")
                for f in sorted(missing_remote):
                    report.append(f"    - {f}")
            
            missing_local = remote_set - local_set
            if missing_local:
                report.append(f"\n  Files in remote but NOT in local ({len(missing_local)}):")
                for f in sorted(missing_local):
                    report.append(f"    - {f}")
            
            common = local_set & remote_set
            if common:
                report.append(f"\n  Files in both ({len(common)}):")
                for f in sorted(common):
                    report.append(f"    - {f}")
        
        # Write report
        os.makedirs(os.path.dirname(output.report), exist_ok=True)
        with open(output.report, 'w') as f:
            f.write('\n'.join(report))
        
        # Also write to log
        with open(log[0], 'w') as f:
            f.write('\n'.join(report))


rule collect_flexbar_report_extras:
    input:
        fragment  = "handoff/flexbar/{config_id}.yaml",
        # Both of these are produced on the conversion side and arrive by rsync;
        # declaring them makes a truncated transfer fail here by name instead of
        # producing a silently unrenamed report attachment.
        barcodes  = "metadata/flexbar_barcodes_{config_id}.txt",
        filesizes = "output/{config_id}/flexbar/size.txt",
        flexbar_log = "output/{config_id}/flexbar/flexbarOut.log"
    output:
        flexbar_log = "Reports/order_{order_id}/flexbarOut_{config_id}.log",
        barcodes    = "Reports/order_{order_id}/flexbar_barcodes_{config_id}.txt",
        filesizes   = "Reports/order_{order_id}/flexbar_filesizes_{config_id}.txt"
    wildcard_constraints:
        config_id = "[^/]+"
    run:
        import shutil, os, re
        config_id = wildcards.config_id
        os.makedirs(f"Reports/order_{wildcards.order_id}", exist_ok=True)
        shutil.copy(input.flexbar_log, output.flexbar_log)

        # Build sample_name -> renamed stem mapping from the handoff fragment
        name_map = {}
        for _row in flexbar_handoff_entry(config_id).get("renaming_rows", []):
            _sname = _row['Sample_Name']
            _idx1 = str(_row.get('index', '') or '')
            _idx2 = str(_row.get('index2', '') or '')
            _bc = f"{_idx1}-{_idx2}" if _idx2 and _idx2.lower() != 'nan' else _idx1
            name_map[_sname] = f"{_row['Run']}-L{_row['Lane']}-G{_row['Group']}-{_row['Position']}-{_bc}"

        # Write barcodes file with renamed sample names in column 1
        with open(input.barcodes) as _fin, \
             open(output.barcodes, 'w') as _fout:
            for _line in _fin:
                _parts = _line.rstrip('\n').split('\t')
                if _parts and _parts[0].strip() in name_map:
                    _parts[0] = name_map[_parts[0].strip()]
                _fout.write('\t'.join(_parts) + '\n')

        # Write filesizes file with renamed FASTQ names
        with open(input.filesizes) as _fin, \
             open(output.filesizes, 'w') as _fout:
            for _line in _fin:
                _parts = _line.rstrip('\n').split('\t')
                if len(_parts) >= 2:
                    _m = re.match(r'flexbarOut_barcode_(.+?)(_R2)?\.fastq\.gz$', _parts[1].strip())
                    if _m:
                        _sname, _r2 = _m.group(1), _m.group(2)
                        _rtype = 'R2' if _r2 else 'R1'
                        if _sname in name_map:
                            _parts[1] = f"{name_map[_sname]}-{_rtype}.fastq.gz"
                _fout.write('\t'.join(_parts) + '\n')


rule report_order_id:
    input:
        # Each handoff entry already carries its own order_id and lane, so
        # membership is a lookup rather than a re-derivation from the config_id
        # string plus an ORDER_ID_TO_LANE cross-check.
        fastp_plots = lambda wildcards: [
            plot for e in handoff_entries_for_order(wildcards.order_id)
            for plot in e["plot_targets"]
        ],
        md5_files = lambda wildcards: [
            e["md5_file"] for e in handoff_entries_for_order(wildcards.order_id)
        ],
        links_yamls = lambda wildcards: [
            f"logs/{e['config_id']}/project_links_{e['config_id']}---{e['project']}.yaml"
            for e in handoff_entries_for_order(wildcards.order_id)
        ]
    output:
        html = "Reports/order_{order_id}/index.html",
        md5 = "Reports/order_{order_id}/md5sums.txt",
        pdf = "Reports/order_{order_id}/Download_Instructions.pdf"
    log:
        "logs/report_order_{order_id}.log"
    benchmark:
        "benchmarks/report_order_id_{order_id}.bench"
    params:
        order_id = "{order_id}",
        output_base = "output",
        fastp_plots_base = "results",
        fastp_base = "results",
        report_dir = "Reports/order_{order_id}"
    run:
        import subprocess
        import sys
        import os
        sys.path.insert(0, workflow.basedir)
        
        import yaml as _yaml

        def _as_file_list(value):
            """Normalize Snakemake named inputs to a list of file paths.

            With a single upstream file, named inputs can be exposed as a scalar path.
            """
            if value is None:
                return []
            if isinstance(value, (str, os.PathLike)):
                return [str(value)]
            try:
                return [str(v) for v in value]
            except TypeError:
                return [str(value)]

        order_id = params.order_id
        report_dir = params.report_dir
        log_file = log[0]

        # Determine lane filter: if this order_id maps to a single lane, filter by it
        _lanes_for_order = ORDER_ID_TO_LANE.get(order_id, [])
        lane_arg = ",".join(str(l) for l in _lanes_for_order) if _lanes_for_order else "None"

        os.makedirs(report_dir, exist_ok=True)

        # Merge individual per-project yaml files into a single dict
        merged_links = {}
        # No glob fallback: the input lambda reads the handoff fragments, which are
        # re-read from disk on every parse including a spawned job's, so it cannot
        # resolve to [] the way the old metadata-derived lambdas could.
        links_yaml_files = _as_file_list(input.links_yamls)
        for yaml_path in links_yaml_files:
            if os.path.exists(yaml_path):
                with open(yaml_path) as _yf:
                    _data = _yaml.safe_load(_yf) or {}
                for _proj, _proj_data in _data.items():
                    for _cfg, _cfg_data in _proj_data.items():
                        # Only include configs that have an entry for this order_id
                        if isinstance(_cfg_data, dict) and order_id not in _cfg_data:
                            continue
                        if _proj not in merged_links:
                            merged_links[_proj] = {}
                        merged_links[_proj][_cfg] = _cfg_data
        merged_yaml_path = os.path.join(report_dir, "_merged_links.yaml")
        with open(merged_yaml_path, 'w') as _yf:
            _yaml.dump(merged_links, _yf, default_flow_style=False)

        projects = sorted(merged_links.keys())

        # Build renamed→original project name mapping for all projects in this order_id.
        # generate_report.py uses this to display original metadata names in the HTML.
        # generate_report.py displays the original metadata project name and looks
        # up fastp JSONs under it.  The conversion workflow recorded the
        # renamed->original mapping per project, which covers bcl, flexbar and fqtk
        # projects uniformly -- no forward/inverse rename-map scanning here.
        import json as _json
        project_name_map = {
            e["project"]: e["orig_project"]
            for e in handoff_entries_for_order(order_id)
        }
        for _proj in projects:
            project_name_map.setdefault(_proj, _proj)
        project_name_map_json = _json.dumps(project_name_map)

        # 10x/Parse/BD naming verdicts come from the fragments, not from a fresh
        # look at the workbook: this host has no workbook, and generate_report.py
        # has to look for the same filenames the conversion run produced. Both the
        # renamed folder and the original project name are listed, since the report
        # resolves either one. See src/single_cell.py.
        _single_cell_names = sorted({
            name
            for e in handoff_entries_for_order(order_id) if e.get("single_cell")
            for name in (e["project"], e.get("orig_project", ""))
            if name
        })
        _report_env = dict(os.environ)
        _report_env["PIPELINE_SINGLE_CELL_PROJECTS"] = ";".join(_single_cell_names)

        # Open log file
        with open(log_file, 'w') as lf:
            lf.write(f"Generating report for order_id: {order_id}\n")
            lf.write(f"Link YAML inputs: {links_yaml_files}\n")
            lf.write(f"Projects: {projects}\n")
            lf.write(f"Project name map: {project_name_map}\n\n")

        # Generate report for each project in this order_id
        for project in projects:
            orig_project = project_name_map.get(project, project)

            # Get fastq links for this project in this order_id
            fastq_links = get_project_links_from_yaml(merged_yaml_path, project, lane=None, order_id=order_id)

            # Call generate_report.py for this project
            cmd = [
                sys.executable, "src/generate_report.py",
                project,
                params.output_base,
                params.fastp_plots_base,
                params.fastp_base,
                report_dir,
                fastq_links,
                lane_arg,  # lane_filter
                merged_yaml_path,
                order_id,
                LIBRARY,  # library_name
                str(config.get('plots_total_width', 900)),
                str(config.get('plots_quality', 35)),
                orig_project,          # orig_project_name for fastp lookups
                project_name_map_json, # full renamed→original map for report display
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, env=_report_env)
            with open(log_file, 'a') as f:
                f.write(f"\n=== Report generation for project {project} ===\n")
                f.write(result.stdout)
                if result.stderr:
                    f.write(f"STDERR: {result.stderr}\n")
        
        # Consolidate md5 sums from all projects in this order_id
        all_md5s = []
        md5_input_files = _as_file_list(input.md5_files)
        for md5_file in md5_input_files:
            try:
                with open(md5_file, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            all_md5s.append(line)
            except Exception as e:
                with open(log_file, 'a') as f:
                    f.write(f"Warning: Could not read {md5_file}: {e}\n")
        
        # Sort consolidated md5s by filename
        all_md5s.sort(key=lambda x: x.split()[1] if len(x.split()) > 1 else x)
        
        # Write consolidated md5sums.txt
        md5_file = os.path.join(report_dir, "md5sums.txt")
        with open(md5_file, 'w') as f:
            for line in all_md5s:
                f.write(line + '\n')
        
        with open(log_file, 'a') as f:
            f.write(f"\nConsolidated {len(all_md5s)} md5 entries into {md5_file}\n")

        # Always generate Download Instructions PDF so rule outputs are complete,
        # even when project discovery returns an empty set.
        pdf_file = os.path.join(report_dir, "Download_Instructions.pdf")
        pdf_cmd = [sys.executable, "src/generate_download_instructions_pdf.py", pdf_file]
        pdf_result = subprocess.run(pdf_cmd, capture_output=True, text=True)
        with open(log_file, 'a') as f:
            f.write("\n=== Download Instructions PDF generation ===\n")
            f.write(pdf_result.stdout)
            if pdf_result.stderr:
                f.write(f"PDF STDERR: {pdf_result.stderr}\n")
        if pdf_result.returncode != 0:
            raise RuntimeError(f"PDF generation failed for order {order_id}")

        # Ensure HTML output exists if no per-project report was generated.
        if not os.path.exists(output.html):
            with open(output.html, 'w') as f:
                f.write(f"<html><body><h1>Order {order_id}</h1><p>No project report entries were generated.</p></body></html>\n")

def rc_orientation_tag(order_id):
    """Subject-line tag naming the RC flavours applied to an order, or ''.

    Built from this order's handoff fragments, not from a run-level summary: an
    order's email must not wait on lanes belonging to other orders.

    Operator-facing only: the manager needs to know an RC workflow ran so he can
    add his own wording for the client, and the report body the client reads is
    deliberately left untouched.
    """
    flipped = set()
    for entry in handoff_entries_for_order(order_id):
        label = rc_index_label(entry.get("orientation", ""))
        flipped.update(tag for tag in label.split('+') if tag)
    if not flipped:
        return ""
    return f" [{rc_tags_label(flipped)} reverse-complement applied]"


rule send_order_email:
    input:
        html = "Reports/order_{order_id}/index.html",
        md5  = "Reports/order_{order_id}/md5sums.txt",
        pdf  = "Reports/order_{order_id}/Download_Instructions.pdf",
        flexbar_extras = lambda wildcards: [
            f"Reports/order_{wildcards.order_id}/{prefix}_{cid}.{ext}"
            for cid in FLEXBAR_CONFIG_BY_ORDER_ID.get(wildcards.order_id, [])
            for prefix, ext in [("flexbarOut", "log"), ("flexbar_barcodes", "txt"), ("flexbar_filesizes", "txt")]
        ]
    output:
        touch("Reports/order_{order_id}/email_sent.done")
    log:
        "logs/send_order_email_{order_id}.log"
    benchmark:
        "benchmarks/send_order_email_{order_id}.bench"
    params:
        script   = "src/send_email.py",
        sender   = EMAIL_SENDER,
        receiver = EMAIL_RECIPIENT,
        cc_email = EMAIL_CC,
        subject  = lambda wildcards: (
            f"Sequencing Report for Order {wildcards.order_id}"
            f"{rc_orientation_tag(wildcards.order_id)}"
        )
    run:
        import subprocess, os
        order_id = wildcards.order_id
        attachments = f"{input.md5};{input.pdf}"
        for cid in FLEXBAR_CONFIG_BY_ORDER_ID.get(order_id, []):
            for prefix, ext in [("flexbarOut", "log"), ("flexbar_barcodes", "txt"), ("flexbar_filesizes", "txt")]:
                extra = f"Reports/order_{order_id}/{prefix}_{cid}.{ext}"
                if os.path.exists(extra):
                    attachments += f";{extra}"
        cmd = [
            "python3", "src/send_email_retry.py",
            params.script, params.sender, params.receiver,
            params.subject, input.html, attachments,
            params.cc_email, order_id
        ]
        with open(log[0], "w") as logf:
            result = subprocess.run(cmd, stdout=logf, stderr=logf)
        if result.returncode != 0:
            raise RuntimeError(f"Email send failed (see {log[0]})")

rule send_read_counts_email:
    input:
        csv = f"results/{LIBRARY}-count.csv",
        # Written by the conversion run and rsynced here; see src/handoff.smk.
        rc_summary = f"{HANDOFF_DIR}/rc_orientation_summary.csv",
        order_reports = ORDER_ID_REPORTS
    output:
        touch(f"Reports/{LIBRARY}_read_counts_email.done")
    log:
        f"logs/send_read_counts_email.log"
    benchmark:
        "benchmarks/send_read_counts_email.bench"
    priority: 80
    params:
        script = "src/send_email.py",
        sender = EMAIL_SENDER,
        receiver = EMAIL_RECIPIENT,
        subject = f"Read counts for {LIBRARY}",
        body = lambda wildcards: (
            f"Attached: per-lane read counts for {LIBRARY}, and the "
            f"reverse-complement orientation summary.\n\n"
            f"The read-count table now carries an 'index_rc' column alongside "
            f"'counts' in each lane/group block. It is blank when the project was "
            f"demultiplexed and delivered on the barcodes as submitted, and reads "
            f"'i7', 'i5', or 'i7+i5' when that index had to be reverse-complemented "
            f"to match the index reads. The FASTQ filenames for those projects carry "
            f"the sequence actually observed, not the submitted one.\n\n"
            f"The orientation summary lists only the flagged projects, with the "
            f"submitted and delivered barcode for each."
        ),
        cc_email = EMAIL_CC
    run:
        import subprocess
        with open(log[0], "w") as logf:
            result = subprocess.run(
                ["python3", params.script, params.sender, params.receiver,
                 params.subject, params.body,
                 f"{input.csv};{input.rc_summary}", params.cc_email],
                stdout=logf, stderr=logf
            )
        if result.returncode != 0:
            raise RuntimeError(f"Email send failed (see {log[0]})")

rule rsync_to_external_drive:
    input:
        # Ensure all reports are generated before running rsync
        reports = ORDER_ID_REPORTS,
        md5s = ORDER_ID_MD5S,
    output:
        touch("logs/rsync_to_external_drive.done")
    log:
        "logs/rsync_to_external_drive.log"
    benchmark:
        "benchmarks/rsync_to_external_drive.bench"
    params:
        dest_dir = EXTERNAL_DRIVE_PATH,
        project_name = LIBRARY,
        src_dir = lambda wildcards: os.getcwd()
    run:
        import sys
        sys.stderr = sys.stdout = open(log[0], 'w')
        if SKIP_RSYNC:
            print(f"Working directory {WORKING_DIR} is on /mnt/ path. Skipping rsync.")
            with open(output[0], 'w') as f:
                f.write('SKIPPED: Already on /mnt/ path')
            return
        if not params.dest_dir:
            print("No external_drive_path specified in config.yaml. Skipping rsync.")
            with open(output[0], 'w') as f:
                f.write('SKIPPED')
            return
        src = os.path.abspath(params.src_dir)
        dest = os.path.join(params.dest_dir, params.project_name)
        print(f"Rsyncing {src} to {dest}")
        os.makedirs(dest, exist_ok=True)
        # Use resume-friendly rsync flags so interrupted transfers can be resumed.
        # --partial preserves partially transferred files; --append-verify resumes and verifies.
        cmd = [
            "rsync", "-aW", "--delete", "--exclude='.snakemake/'", src + "/", dest + "/", "--exclude", "*Undetermined*"
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        print(result.stdout)
        if result.stderr:
            print("STDERR:", result.stderr)
        with open(output[0], 'w') as f:
            f.write('DONE')


# Diagnostic rule: print expected and actual .done and .log files for project_link
rule debug_project_link_files:
    run:
        import os
        print("\n=== DIAGNOSTIC: CONFIG_PROJECT_PAIRS ===")
        for config_id, project in CONFIG_PROJECT_PAIRS:
            print(f"PAIR: config_id={config_id}, project={project}")
        print("\n=== DIAGNOSTIC: Expected .done files ===")
        for config_id, project in CONFIG_PROJECT_PAIRS:
            done_path = f".output/{config_id}/.done"
            print(f"{done_path}: {'EXISTS' if os.path.exists(done_path) else 'MISSING'}")
        print("\n=== DIAGNOSTIC: Expected .log files ===")
        for config_id, project in CONFIG_PROJECT_PAIRS:
            log_path = f"logs/{config_id}/project_link_{config_id}_{project}.log"
            print(f"{log_path}: {'EXISTS' if os.path.exists(log_path) else 'MISSING'}")
        print("\n=== DIAGNOSTIC: All files in logs/ matching project_link_*.log ===")
        for fname in sorted(os.listdir('logs')):
                if fname.startswith('project_link_') and fname.endswith('.log'):
                    print(fname)




rule send_low_reads_alerts:
    """Send the low-reads alerts the conversion workflow detected.

    Detection needs Demultiplex_Stats.csv and happens on the conversion side;
    only the send needs a mail relay, so the conversion workflow writes a JSON
    payload per project and this rule delivers whichever ones are non-empty.
    """
    input:
        alerts = lambda wildcards: [
            f"handoff/alerts/{e['config_id']}---{e['project']}.json"
            for e in HANDOFF_ENTRIES
        ]
    output:
        touch(f"Reports/{LIBRARY}_low_reads_alerts.done")
    log:
        "logs/send_low_reads_alerts.log"
    params:
        sender   = EMAIL_SENDER,
        receiver = EMAIL_RECIPIENT,
        cc       = EMAIL_CC
    run:
        import json, subprocess

        sent = failed = 0
        with open(log[0], "w") as lf:
            for path in input.alerts:
                with open(path) as fh:
                    payload = json.load(fh)
                if not payload.get("samples"):
                    continue
                result = subprocess.run(
                    ["python3", "src/send_email.py",
                     params.sender, params.receiver,
                     payload["subject"], payload["body"], "none", params.cc],
                    capture_output=True, text=True
                )
                lf.write(f"{path}: {payload['subject']}\n{result.stdout}\n")
                if result.returncode != 0:
                    failed += 1
                    lf.write(f"  send failed (exit {result.returncode}): {result.stderr}\n")
                else:
                    sent += 1
            lf.write(f"\nSent {sent} alert(s), {failed} failure(s).\n")
        if failed:
            raise RuntimeError(f"{failed} low-reads alert email(s) failed (see {log[0]})")
