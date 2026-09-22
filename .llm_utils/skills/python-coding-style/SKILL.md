---
name: python-coding-style
description: Provides general instructions on how to write Python code. Use when writing or modifying Python code.
---

# General
The following rules should apply to any Python code written, unless user instructs to do otherwise.

# Style and Formatting
- stick to PEP8;
- use double quotes for for single or multiline strings by default (literals containing double quotes may be wrapped into single-quotted strings);

# Naming
- file & directory names must consist of lowercase letters, digits and underscores, which separate words;
- file & directory names should either have the name of the main artifact inside them or reflect the meaning of contents inside them;

# Comments
- add docstrings and comments to functions & methods, but keep them short:
    - docstrings should contain:
        - basic description of the function;
        - important non-obvious information about function parameters;
        - parameters & return value descriptions should be kept as short as possible;
    - comments should be added only:
        - to explain complex code parts;
        - to explain business rules and edge cases, which are not obvious from the scope of the function;
- do not update or remove existing comments, unless the related to the comment code is changed;

# Code Writing Guidelines
- use type hints for code you add or update:
    - if current project has a type checking tool, check its configuration for ignored errors;
- use newer features of Python when appropriate, if Python version is specified (e.g. use `list[str] | list[int]` instead of `Union[List[str], List[int]]`);
- use absolute imports, when imports from other files of the project:
    - import path must start from a direct child of the project's root directory;
    - if a file is executable, ensure project root is in sys.path (check if file runs correctly after this line is added):
        ```python
        # somewhere at the top of the file
        import sys
        from pathlib import Path
        PROJECT_ROOT = Path(__file__).parents[1]    # path of the project root directory
        if __name__ == "__main__":
            sys.path.insert(0, str(PROJECT_ROOT))
        ```
- do not add default values for function arguments, unless it's explicitly required by task (or makes a strong sense) to do otherwise;
