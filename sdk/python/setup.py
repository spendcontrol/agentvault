"""Setup script for the yieldvault Python SDK."""

from setuptools import setup, find_packages

setup(
    name="yieldvault",
    version="0.1.0",
    description="Python SDK for AI agents to interact with YieldVault contracts",
    author="YieldVault contributors",
    license="MIT",
    packages=find_packages(),
    python_requires=">=3.10",
    install_requires=[
        "web3>=6.0.0",
    ],
    extras_require={
        "dev": [
            "pytest",
            "pytest-asyncio",
        ],
    },
)
