BASE = {
    "CRITICAL": (1, 15),
    "HIGH": (2, 60),
    "MEDIUM": (3, 240),
    "LOW": (4, 1440),
}


def lambda_handler(event, context):
    # event is one incident (see validate.py)
    priority, sla_minutes = BASE[event["severity"]]
    # security problems are handled one level faster than their severity says
    if event.get("type") == "security" and priority > 1:
        priority -= 1
    return {"priority": priority, "sla_minutes": sla_minutes}
