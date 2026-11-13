#!/usr/bin/env python3
"""Read-only authenticated contract probe. Never prints credentials or payloads.
Set RAVEN_ORIGIN and RAVEN_ACCESS_TOKEN in your environment. No mutation endpoints.
"""
import json, os, ssl, sys, urllib.request, urllib.error, urllib.parse

class SameOrigin(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Do not forward even to a same-origin redirect: fixtures should pin routes.
        raise RuntimeError('Redirect rejected; configure the canonical site origin')

def main():
    origin = os.environ.get('RAVEN_ORIGIN', '')
    token = os.environ.get('RAVEN_ACCESS_TOKEN', '')
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ('', '/') or not token:
        sys.exit('Set HTTPS RAVEN_ORIGIN (origin only) and RAVEN_ACCESS_TOKEN. No values are logged.')
    opener = urllib.request.build_opener(SameOrigin(), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    methods = [
        ('raven.api.native.boot', dict),
        ('raven.api.raven_users.get_current_raven_user', dict),
        ('raven.api.workspaces.get_list', list),
        ('raven.api.raven_channel.get_all_channels', dict),
        ('raven.api.raven_message.get_unread_count_for_channels', (dict, list)),
        ('raven.api.notifications.get_notifications', list),
        ('raven.api.reminders.get_reminders', list),
        ('raven.api.scheduled_message.get_scheduled_messages', list),
        ('raven.api.reactions.most_used_reactions', list),
    ]
    failed = 0
    for method, expected in methods:
        request = urllib.request.Request(origin.rstrip('/') + '/api/method/' + method, headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/json'})
        try:
            with opener.open(request, timeout=30) as response:
                data = response.read(8 * 1024 * 1024 + 1)
                if len(data) > 8 * 1024 * 1024: raise ValueError('oversized response')
                result = json.loads(data)
                if not isinstance(result.get('message'), expected): raise ValueError('unexpected envelope')
            print('PASS', method)
        except urllib.error.HTTPError as error:
            print('FAIL', method, 'HTTP', error.code); failed += 1
        except Exception as error:
            print('FAIL', method, type(error).__name__); failed += 1
    print('Record installed Raven/Frappe versions AND revisions separately. These reads do not validate mutation, socket, media, permission-revocation or cross-client behavior.')
    return bool(failed)
if __name__ == '__main__': sys.exit(main())
