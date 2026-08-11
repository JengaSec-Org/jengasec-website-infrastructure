# `templates/`

Jinja2 templates shared across roles.

**Empty on purpose.** Every template in this repository currently belongs to the
role that renders it, in `roles/<role>/templates/`, because Ansible's `template`
module resolves that path automatically and because a template beside its role
is a template you can find.

This directory exists for a template genuinely used by more than one role — a
shared header, or a common systemd unit fragment. Reference it with an explicit
path from the task:

```yaml
- name: Render a shared template
  ansible.builtin.template:
    src: "{{ playbook_dir }}/../templates/shared.conf.j2"
    dest: /etc/shared.conf
```

That awkwardness is intentional. If a template is worth sharing it is worth the
explicit path; if it is not, it belongs in its role.

## House style for templates

Every template in this repository:

1. **Starts with the managed banner:**
   ```jinja
   # {{ common_managed_banner }}
   ```
   in whatever comment syntax the target file uses (`#`, `//`, `;`, `"`).

2. **Explains the reasoning, not the syntax.** `# install nginx` above a line
   installing nginx is noise. `# reload, not restart, so existing sessions
   survive` is the comment worth writing.

3. **Contains no literal values that could be variables.** Ports, paths, and
   hostnames come from `defaults` or `group_vars`.

4. **Says how to verify the result** where there is a command for it:
   ```jinja
   # Check this file:  named-checkzone {{ dns_zone }} {{ dns_zone_dir }}/db.{{ dns_zone }}
   ```
