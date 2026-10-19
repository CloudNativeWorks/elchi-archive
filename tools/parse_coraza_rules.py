#!/usr/bin/env python3
"""
Coraza WAF CRS Rule Parser
Fetches Coraza proxy-wasm repository, parses CRS rules, and generates JSON output.

Usage:
    python3 scripts/parse_coraza_rules.py

Output:
    pkg/waf/crs_rules.json
"""

import os
import re
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Dict, Any, Optional

# Configuration
CORAZA_REPO = "https://github.com/corazawaf/coraza-proxy-wasm.git"
CORAZA_VERSION = "0.6.0"
TEMP_DIR = "/tmp/coraza-proxy-wasm"
OUTPUT_DIR = "pkg/waf/data"
RULES_PATH = "wasmplugin/rules/crs"


class ModSecurityRuleParser:
    """Parser for ModSecurity Core Rule Set files"""

    def __init__(self, crs_version: str = "4.8.0"):
        self.crs_version = crs_version
        self.rules: List[Dict[str, Any]] = []

    def parse_conf_file(self, file_path: str) -> List[Dict[str, Any]]:
        """Parse a single .conf file and extract all rules"""
        rules = []

        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        file_name = os.path.basename(file_path)

        i = 0
        while i < len(lines):
            line = lines[i].strip()

            # Detect rule start
            if line.startswith('SecRule') or line.startswith('SecAction'):
                # Collect comment lines before this rule
                comment_lines = []
                j = i - 1
                while j >= 0:
                    prev_line = lines[j].strip()
                    if prev_line.startswith('#'):
                        comment_lines.insert(0, prev_line.lstrip('#').strip())
                        j -= 1
                    elif prev_line == '':
                        j -= 1
                    else:
                        break

                # Collect complete rule (handle multi-line with backslash)
                rule_lines = []
                while i < len(lines):
                    current = lines[i].rstrip()
                    rule_lines.append(current)

                    # Check if line ends with backslash (continuation)
                    if current.endswith('\\'):
                        i += 1
                    else:
                        # Rule complete
                        break

                rule_text = '\n'.join(rule_lines)
                parsed_rule = self._parse_rule(rule_text, file_name, comment_lines)

                if parsed_rule and parsed_rule['characteristics']['id'] > 0:
                    rules.append(parsed_rule)

            i += 1

        return rules

    def _parse_rule(self, rule_text: str, file_name: str, comments: List[str]) -> Optional[Dict[str, Any]]:
        """Parse individual rule and extract metadata"""

        # Parse comment sections
        parsed_comments = self._parse_comment_sections(comments)

        rule_dict = {
            "title": parsed_comments.get('title', ''),
            "description": {
                "short": "",
                "extended": parsed_comments.get('description', ''),
                "exploit": parsed_comments.get('exploit', ''),
                "rule": self._clean_rule_text(rule_text),
                "rulelink": "",
                "rule_logic": parsed_comments.get('rule_logic', ''),
                "targets_info": parsed_comments.get('targets_info', '')
            },
            "crs_version": self.crs_version,
            "references": parsed_comments.get('references', []),
            "rule_type": "",
            "build_instructions": "",
            "link_to_rule_tests": "",
            "example_payloads": {
                "positive": [],
                "negative": []
            },
            "characteristics": {
                "id": 0,
                "phase": 0,
                "paranoia_level": 0,
                "severity": "",
                "file": file_name,
                "tags": [],
                "siblings": [],
                "targets": [],
                "operator": [],
                "transformations": [],
                "capec": [],
                "chained": "No"
            }
        }

        # Extract ID
        id_match = re.search(r'id:(\d+)', rule_text)
        if id_match:
            rule_dict['characteristics']['id'] = int(id_match.group(1))

        # Extract Phase
        phase_match = re.search(r'phase:(\d+)', rule_text)
        if phase_match:
            rule_dict['characteristics']['phase'] = int(phase_match.group(1))

        # Extract Severity
        severity_match = re.search(r"severity:['\"]?([^',\"\\]+)['\"]?", rule_text)
        if severity_match:
            rule_dict['characteristics']['severity'] = severity_match.group(1).strip()

        # Extract Message
        msg_match = re.search(r"msg:['\"]([^'\"]+)['\"]", rule_text)
        if msg_match:
            msg = msg_match.group(1)
            rule_dict['description']['short'] = msg

            # Use msg as title if no title from comments
            if not parsed_comments.get('title'):
                rule_dict['title'] = msg

        # Extract Tags
        tag_matches = re.findall(r"tag:['\"]([^'\"]+)['\"]", rule_text)
        rule_dict['characteristics']['tags'] = tag_matches

        # Extract CAPEC from tags
        capec_tags = [tag for tag in tag_matches if tag.startswith('capec/')]
        rule_dict['characteristics']['capec'] = capec_tags

        # Extract Transformations
        trans_match = re.search(r't:([^,\\\s]+(?:,t:[^,\\\s]+)*)', rule_text)
        if trans_match:
            trans_str = trans_match.group(1)
            transformations = [t.strip() for t in trans_str.replace('t:', '').split(',')]
            rule_dict['characteristics']['transformations'] = transformations

        # Extract Targets (variables)
        target_match = re.search(r'SecRule\s+([^\s"]+)\s+"', rule_text)
        if target_match:
            targets = target_match.group(1).split('|')
            rule_dict['characteristics']['targets'] = [[t.strip()] for t in targets]

        # Extract Operator
        operator_match = re.search(r'"(@\w+)', rule_text)
        if operator_match:
            rule_dict['characteristics']['operator'] = [operator_match.group(1)]

        # Extract Paranoia Level from tag
        pl_match = re.search(r'paranoia[-_]level/(\d+)', rule_text)
        if pl_match:
            rule_dict['characteristics']['paranoia_level'] = int(pl_match.group(1))
        else:
            # Try alternative format
            pl_match = re.search(r'pl:(\d+)', rule_text)
            if pl_match:
                rule_dict['characteristics']['paranoia_level'] = int(pl_match.group(1))

        # Check if chained
        if re.search(r'\bchain\b', rule_text):
            rule_dict['characteristics']['chained'] = "Yes"

        # Determine rule type
        if 'deny' in rule_text or 'block' in rule_text or 'drop' in rule_text:
            rule_dict['rule_type'] = 'blocking'
        elif 'pass' in rule_text:
            rule_dict['rule_type'] = 'detection'
        elif 'setvar' in rule_text and 'INITIALIZATION' in file_name:
            rule_dict['rule_type'] = 'config'
        elif 'REQUEST-900' in file_name or 'RESPONSE-999' in file_name:
            rule_dict['rule_type'] = 'admin-scaffolding'
        else:
            rule_dict['rule_type'] = 'detection'

        # Generate GitHub link
        if rule_dict['characteristics']['id'] > 0:
            rule_dict['description']['rulelink'] = (
                f"https://github.com/coreruleset/coreruleset/blob/v{self.crs_version.lstrip('v')}/"
                f"rules/{file_name}#L{rule_dict['characteristics']['id']}"
            )

        return rule_dict

    def _parse_comment_sections(self, comments: List[str]) -> Dict[str, Any]:
        """Parse structured comment sections"""
        result = {
            'title': '',
            'description': '',
            'rule_logic': '',
            'targets_info': '',
            'references': [],
            'exploit': ''
        }

        current_section = None
        section_buffer = []

        # Filter out copyright/license header comments
        filtered_comments = []
        found_real_content = False

        for comment in comments:
            lower = comment.lower()
            stripped = comment.strip()

            # Skip copyright, license, version headers
            if any(keyword in lower for keyword in [
                'copyright', 'license', 'owasp crs ver', 'apache software',
                'trustwave', 'crs project', 'please see', 'enclosed license',
                'all rights reserved', 'distributed under'
            ]):
                continue

            # Skip separator lines
            if stripped.startswith('---') or stripped == '':
                if not found_real_content:
                    continue
                filtered_comments.append(comment)
                continue

            # Real content found
            found_real_content = True
            filtered_comments.append(comment)

        comments = filtered_comments

        for comment in comments:
            # Detect section headers
            section_match = re.match(r'^-=\[\s*(.+?)\s*\]=-$', comment)
            if section_match:
                # Save previous section
                if current_section and section_buffer:
                    content = '\n'.join(section_buffer).strip()
                    if 'logic' in current_section.lower():
                        result['rule_logic'] = content
                    elif 'target' in current_section.lower():
                        result['targets_info'] = content
                    elif 'reference' in current_section.lower():
                        result['description'] += '\n\n' + content
                    else:
                        if not result['description']:
                            result['description'] = content
                        else:
                            result['description'] += '\n\n' + content

                # Start new section
                current_section = section_match.group(1)
                section_buffer = []

                # Don't use section headers as title (they are metadata like "Rule Logic", "References")
                # Title should come from actual rule description
            elif comment.strip():
                section_buffer.append(comment.strip())

            # Extract references
            urls = re.findall(r'https?://[^\s]+', comment)
            result['references'].extend(urls)

        # Save last section
        if current_section and section_buffer:
            content = '\n'.join(section_buffer).strip()
            if 'logic' in current_section.lower():
                result['rule_logic'] = content
            elif 'target' in current_section.lower():
                result['targets_info'] = content
            else:
                if not result['description']:
                    result['description'] = content
                else:
                    result['description'] += '\n\n' + content

        # If no sections found, use simple logic
        if not result['description'] and comments:
            # Find first non-empty comment block (skip section markers)
            for i, comment in enumerate(comments):
                stripped = comment.strip()
                # Skip section markers like "-=[ ... ]=-" and "Paranoia Level" markers
                if stripped and not stripped.startswith('-') and 'paranoia level' not in stripped.lower():
                    result['title'] = stripped
                    if i + 1 < len(comments):
                        result['description'] = '\n'.join([c.strip() for c in comments[i+1:] if c.strip()])
                    break

        # Deduplicate references — sorted, so two parses of one rule set
        # produce identical JSON (a set's order is not stable across runs).
        result['references'] = sorted(set(result['references']))

        return result

    def _clean_rule_text(self, text: str) -> str:
        """Clean and format rule text"""
        # Remove excessive whitespace
        text = re.sub(r'\s+', ' ', text)
        # Restore line breaks at backslashes
        text = re.sub(r'\s*\\\s*', ' \\\n    ', text)
        return text.strip()


def clone_coraza_repo(version: str = CORAZA_VERSION) -> str:
    """Clone Coraza proxy-wasm repository"""
    print(f"🔽 Cloning Coraza proxy-wasm {version}...")

    # Remove existing temp directory
    if os.path.exists(TEMP_DIR):
        shutil.rmtree(TEMP_DIR)

    # Clone repository
    try:
        subprocess.run([
            'git', 'clone',
            '--depth', '1',
            '--branch', version,
            CORAZA_REPO,
            TEMP_DIR
        ], check=True, capture_output=True)
        print(f"✅ Repository cloned to {TEMP_DIR}")
        return TEMP_DIR
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to clone repository: {e.stderr.decode()}")
        sys.exit(1)


def find_crs_version(repo_path: str = None, rules_path: str = None) -> str:
    """Detect the CRS version from the rule headers (repo_path + RULES_PATH, or an
    explicit rules_path for the shield/coreruleset source)."""
    if rules_path is None:
        rules_path = os.path.join(repo_path, RULES_PATH)

    # Check for version in file comments
    for conf_file in Path(rules_path).glob("*.conf"):
        with open(conf_file, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read(2000)  # Read first 2000 chars

            # Look for version in comments
            version_match = re.search(r'OWASP_CRS/(\d+\.\d+\.\d+)', content)
            if version_match:
                return version_match.group(1)

            version_match = re.search(r'ver:[\'"]OWASP_CRS/(\d+\.\d+\.\d+)', content)
            if version_match:
                return version_match.group(1)

    # Default version
    return "4.8.0"


def parse_all_rules(repo_path: str = None, rules_path: str = None, crs_version_override: str = None) -> List[Dict[str, Any]]:
    """Parse all CRS rules from a repository (WASM: repo_path + RULES_PATH) or from an
    explicit rules directory (shield: the coraza-coreruleset @owasp_crs dir)."""
    if rules_path is None:
        rules_path = os.path.join(repo_path, RULES_PATH)

    if not os.path.exists(rules_path):
        print(f"❌ Rules directory not found: {rules_path}")
        sys.exit(1)

    print(f"📁 Parsing rules from: {rules_path}")

    # Detect CRS version from the rules, unless the caller pinned one (the shield
    # source is keyed by the coraza-coreruleset module version shield reports).
    crs_version = crs_version_override or find_crs_version(rules_path=rules_path)
    print(f"🏷️  Detected CRS version: {crs_version}")

    parser = ModSecurityRuleParser(crs_version)
    all_rules = []

    conf_files = sorted(Path(rules_path).glob("*.conf"))

    for conf_file in conf_files:
        print(f"   Parsing {conf_file.name}...", end=' ')
        try:
            rules = parser.parse_conf_file(str(conf_file))
            all_rules.extend(rules)
            print(f"✅ {len(rules)} rules")
        except Exception as e:
            print(f"❌ Error: {e}")

    return all_rules


def save_rules_json(rules: List[Dict[str, Any]], output_dir: str, crs_version: str, coraza_version: str, prefix: str = "crs_rules_"):
    """Save rules to a versioned JSON file. `prefix` separates the WASM library
    (crs_rules_<ver>.json) from the shield library (crs_rules_coreruleset_<ver>.json)."""
    # Create output directory if needed
    os.makedirs(output_dir, exist_ok=True)

    # Versioned filename
    output_file = os.path.join(output_dir, f"{prefix}{crs_version}.json")

    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(rules, f, indent=2, ensure_ascii=False)

    print(f"💾 Saved {len(rules)} rules to {output_file}")

    # Also save metadata file
    metadata = {
        "coraza_version": coraza_version,
        "crs_version": crs_version,
        "total_rules": len(rules),
        "generated_at": __import__('datetime').datetime.now().isoformat()
    }

    metadata_file = os.path.join(output_dir, f"{prefix}{crs_version}_metadata.json")
    with open(metadata_file, 'w', encoding='utf-8') as f:
        json.dump(metadata, f, indent=2)

    print(f"📋 Metadata saved to {metadata_file}")

    # Print statistics
    rule_types = {}
    severities = {}
    for rule in rules:
        rt = rule.get('rule_type', 'unknown')
        rule_types[rt] = rule_types.get(rt, 0) + 1

        sev = rule['characteristics'].get('severity', 'unknown')
        severities[sev] = severities.get(sev, 0) + 1

    print("\n📊 Statistics:")
    print(f"   Total rules: {len(rules)}")
    print(f"   Rule types: {dict(rule_types)}")
    print(f"   Severities: {dict(severities)}")


def cleanup(repo_path: str):
    """Remove temporary repository"""
    if os.path.exists(repo_path):
        shutil.rmtree(repo_path)
        print(f"🧹 Cleaned up {repo_path}")


def validate_rules(rules: List[Dict[str, Any]]) -> None:
    """Sanity-check the parsed rules before writing the library — generation-time only,
    so it never affects the running controller. Empty is fatal (caller exits); duplicate
    or missing ids are surfaced as warnings (the parser is heuristic, so we flag anomalies
    rather than fail the build)."""
    from collections import Counter
    ids = [r.get('characteristics', {}).get('id', 0) for r in rules]
    non_zero = [i for i in ids if i]
    zero = len(ids) - len(non_zero)
    dupes = {i: n for i, n in Counter(non_zero).items() if n > 1}

    print(f"🔎 Validation: {len(rules)} rules, {len(set(non_zero))} distinct ids")
    if zero:
        print(f"   ⚠️  {zero} rule(s) carry no id")
    if dupes:
        print(f"   ⚠️  {len(dupes)} duplicate id(s), e.g. {list(dupes.items())[:5]}")
    else:
        print("   ✓ all rule ids unique")


def main():
    """Main execution.

    Two sources:
      • WASM (default, no args): clones coraza-proxy-wasm and emits
        crs_rules_<crs_version>.json — the envoy WASM WAF library. UNCHANGED.
      • Shield (--rules-dir): parses an explicit rules directory (the
        coraza-coreruleset @owasp_crs dir the shield binary embeds) and emits
        crs_rules_coreruleset_<version>.json — the shield WAF Studio library.
        Pin the label with --crs-version so it matches what shield reports.
    """
    import argparse
    ap = argparse.ArgumentParser(description="Parse OWASP CRS .conf rules into the elchi CRS library JSON.")
    ap.add_argument("--rules-dir", help="explicit rules dir (shield/coreruleset source); skips the proxy-wasm clone")
    ap.add_argument("--crs-version", help="version label for the output file (e.g. v4.25.0)")
    ap.add_argument("--coraza-version", default=CORAZA_VERSION, help="coraza version stamped in metadata")
    ap.add_argument("--out-prefix", help="output filename prefix (default crs_rules_ for WASM, crs_rules_coreruleset_ for --rules-dir)")
    ap.add_argument("--output-dir", default=OUTPUT_DIR)
    args = ap.parse_args()

    print("=" * 60)
    print("Coraza WAF CRS Rule Parser")
    print("=" * 60)
    print()

    try:
        repo_path = None
        if args.rules_dir:
            # Shield source: parse the coreruleset rules directly, no clone.
            rules = parse_all_rules(rules_path=args.rules_dir, crs_version_override=args.crs_version)
            prefix = args.out_prefix or "crs_rules_coreruleset_"
        else:
            # WASM source (unchanged default).
            repo_path = clone_coraza_repo(args.coraza_version)
            rules = parse_all_rules(repo_path, crs_version_override=args.crs_version)
            prefix = args.out_prefix or "crs_rules_"

        if not rules:
            print("❌ No rules found!")
            sys.exit(1)

        validate_rules(rules)

        # The version label: an explicit --crs-version wins; else what the rules declared.
        crs_version = args.crs_version or rules[0].get('crs_version', 'unknown')

        save_rules_json(rules, args.output_dir, crs_version, args.coraza_version, prefix=prefix)

        if repo_path:
            cleanup(repo_path)

        print()
        print("=" * 60)
        print(f"✅ Done! Rules saved to {args.output_dir}/{prefix}{crs_version}.json")
        print("=" * 60)

    except KeyboardInterrupt:
        print("\n⚠️  Interrupted by user")
        cleanup(TEMP_DIR)
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
        cleanup(TEMP_DIR)
        sys.exit(1)


if __name__ == "__main__":
    main()
