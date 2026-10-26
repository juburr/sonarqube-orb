"""Greetings, with issues for SonarQube to find."""


def greet(name):
    unused = 42
    # TODO: greet in other languages too
    return "Hello, " + name + "!"


def farewell(name):
    if name == name:
        return "Goodbye, " + name + "."
    return "Goodbye."
