use regex::Regex;

/// Expand environment variables in a string (${VAR_NAME} syntax)
pub fn expand_env_vars(input: &str) -> String {
    let re = Regex::new(r"\$\{([^}]+)\}").expect("invalid regex");
    re.replace_all(input, |caps: &regex::Captures| {
        let var_name = &caps[1];
        std::env::var(var_name).unwrap_or_default()
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_expand_env_vars() {
        std::env::set_var("TEST_SKYCLAW_VAR", "hello");
        assert_eq!(expand_env_vars("${TEST_SKYCLAW_VAR}"), "hello");
        assert_eq!(expand_env_vars("prefix_${TEST_SKYCLAW_VAR}_suffix"), "prefix_hello_suffix");
        assert_eq!(expand_env_vars("no_vars_here"), "no_vars_here");
        assert_eq!(expand_env_vars("${NONEXISTENT_VAR}"), "");
        std::env::remove_var("TEST_SKYCLAW_VAR");
    }
}
