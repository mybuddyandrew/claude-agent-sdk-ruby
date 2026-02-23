# Heartbeat Checklist

This file is evaluated periodically by the Skein kernel. If everything is fine, respond with HEARTBEAT_OK. If any item needs attention, explain what action should be taken.

## Checks

- [ ] No unprocessed tasks older than 30 minutes
- [ ] No tasks stuck in "running" state for more than 5 minutes
- [ ] No failed tasks that haven't been reported to the user
