# Sergio — CV & Technical Portfolio

I'm a vocational student interested in artificial intelligence, robotics, and open-source software. I use practical projects to learn, investigate reliability issues, and build small, testable improvements.

## Selected work

### DeepSeek-V3 — safer FP8 conversion output

I proposed a change to make FP8-to-BF16 conversion publish its output transactionally: stage converted files, validate the resulting index, and preserve existing output if publication fails.

- [Pull request #1706 — `fix(inference): publish FP8 conversion output transactionally`](https://github.com/deepseek-ai/DeepSeek-V3/pull/1706)
- **Status:** open and awaiting upstream review; not merged.
- **Validation note:** the PR description records Python compilation and diff checks as passed. The targeted pytest suite was not run in the reported environment because the required dependencies were unavailable.

## Areas I'm exploring

- AI inference and local-model tooling
- Python, testing, and software reliability
- Robotics and automation
- Open-source collaboration and technical documentation

## Links

- [GitHub profile](https://github.com/secheverrianogal-beep)
- [DeepSeek-V3 fork](https://github.com/secheverrianogal-beep/DeepSeek-V3)

---

This portfolio highlights work in progress as well as completed work. A proposed change is not described as accepted or merged unless the upstream repository confirms it.
