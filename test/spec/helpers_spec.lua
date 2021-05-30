local stub = require("luassert.stub")
local loop = require("null-ls.loop")

local c = require("null-ls.config")
local test_utils = require("test.utils")

describe("helpers", function()
    _G._TEST = true

    stub(vim, "validate")

    local done = stub.new()
    local on_output = stub.new()

    after_each(function()
        done:clear()
        on_output:clear()
        vim.validate:clear()
    end)

    local helpers = require("null-ls.helpers")
    describe("json_output_wrapper", function()
        it("should throw error if json decode fails", function()
            local bad_json = "this is not json"

            assert.has_error(function()
                helpers._json_output_wrapper({ output = bad_json }, done, on_output)
            end)
        end)

        it("should set output to decoded json", function()
            local good_json = vim.fn.json_encode({ key = "val" })

            helpers._json_output_wrapper({ output = good_json }, done, on_output)

            local output = on_output.calls[1].refs[1].output
            assert.same(output, { key = "val" })
        end)

        it("should call done and on_output with updated params", function()
            local good_json = vim.fn.json_encode({ key = "val" })

            helpers._json_output_wrapper({ output = good_json }, done, on_output)

            assert.stub(done).was_called()
            assert.stub(on_output).was_called_with({ output = { key = "val" } })
        end)
    end)

    describe("line_output_wrapper", function()
        it("should immediately call done if output is nil", function()
            helpers._line_output_wrapper({ output = nil }, done, on_output)

            assert.stub(done).was_called()
            assert.stub(on_output).was_not_called()
        end)

        it("should call on_output once for each line", function()
            helpers._line_output_wrapper({ output = "line1\nline2\nline3" }, done, on_output)

            assert.stub(on_output).was_called(3)
            assert.equals(on_output.calls[1].refs[1], "line1")
            assert.equals(on_output.calls[2].refs[1], "line2")
            assert.equals(on_output.calls[3].refs[1], "line3")
        end)

        it("should call done with all_results", function()
            on_output.returns({ "results" })

            helpers._line_output_wrapper({ output = "line1\nline2\nline3" }, done, on_output)

            assert.same(done.calls[1].refs[1], { { "results" }, { "results" }, { "results" } })
        end)
    end)

    describe("generator_factory", function()
        stub(loop, "spawn")

        local command = "cat"
        local args = { "-n" }
        local generator_args
        before_each(function()
            generator_args = {
                command = command,
                args = args,
                on_output = function(...)
                    on_output(...)
                end,
            }
        end)

        after_each(function()
            loop.spawn:clear()

            vim.cmd("bufdo! bwipeout!")
        end)

        it("should validate opts on first run", function()
            local generator = helpers.generator_factory(generator_args)

            generator.fn({})

            assert.stub(vim.validate).was_called()
        end)

        it("should not validate opts on subsequent runs", function()
            local generator = helpers.generator_factory(generator_args)

            generator.fn({})
            generator.fn({})

            assert.stub(vim.validate).was_called(1)
        end)

        it("should set async to true", function()
            local generator = helpers.generator_factory(generator_args)

            assert.equals(generator.async, true)
        end)

        it("should pass filetypes to generator", function()
            generator_args.filetypes = { "lua" }
            local generator = helpers.generator_factory(generator_args)

            assert.same(generator.filetypes, { "lua" })
        end)

        describe("fn", function()
            it("should call loop.spawn with command and args", function()
                local generator = helpers.generator_factory(generator_args)

                generator.fn({})

                assert.stub(loop.spawn).was_called()
                assert.equals(loop.spawn.calls[1].refs[1], command)
                assert.same(loop.spawn.calls[1].refs[2], args)
            end)

            it("should call loop.spawn with default args (empty table)", function()
                generator_args.args = nil
                local generator = helpers.generator_factory(generator_args)

                generator.fn({})

                assert.same(loop.spawn.calls[1].refs[2], {})
            end)

            it("should call loop.spawn with specified timeout", function()
                generator_args.timeout = 500
                local generator = helpers.generator_factory(generator_args)

                generator.fn({})

                assert.same(loop.spawn.calls[1].refs[3].timeout, 500)
            end)

            it("should call loop.spawn with default timeout", function()
                generator_args.timeout = nil
                local generator = helpers.generator_factory(generator_args)

                generator.fn({})

                assert.same(loop.spawn.calls[1].refs[3].timeout, c.get().default_timeout)
            end)

            it("should call loop.spawn with buffer content as string when to_stdin = true", function()
                test_utils.edit_test_file("test-file.lua")
                local params = { bufnr = vim.api.nvim_get_current_buf() }
                generator_args.to_stdin = true
                local generator = helpers.generator_factory(generator_args)

                generator.fn(params)

                local input = loop.spawn.calls[1].refs[3].input
                assert.equals(input, 'print("I am a test file!")\n')
            end)
        end)

        describe("wrapper", function()
            it("should set params.output and call on_output with params and done", function()
                local generator = helpers.generator_factory(generator_args)
                generator.fn({}, done)

                local wrapper = loop.spawn.calls[1].refs[3].handler
                wrapper(nil, "output")

                assert.stub(on_output).was_called_with({ output = "output" }, done)
            end)

            it("should set output to error_output and error_output to nil if to_stderr = true", function()
                generator_args.to_stderr = true
                local generator = helpers.generator_factory(generator_args)
                generator.fn({}, done)

                local wrapper = loop.spawn.calls[1].refs[3].handler
                wrapper("error output", nil)

                assert.stub(on_output).was_called_with({ output = "error output" }, done)
            end)

            it("should throw error if error_output exists and format ~= raw", function()
                local generator = helpers.generator_factory(generator_args)
                generator.fn({}, done)

                local wrapper = loop.spawn.calls[1].refs[3].handler
                assert.has_error(function()
                    wrapper("error output", nil)
                end)
            end)

            it("should set params.err if format == raw", function()
                generator_args.format = "raw"
                local generator = helpers.generator_factory(generator_args)
                generator.fn({}, done)

                local wrapper = loop.spawn.calls[1].refs[3].handler
                wrapper("error output", nil)

                assert.stub(on_output).was_called_with({ err = "error output" }, done)
            end)

            it("should call json_output_wrapper and return if format == json", function()
                generator_args.format = "json"
                local generator = helpers.generator_factory(generator_args)
                generator.fn({}, done)

                local wrapper = loop.spawn.calls[1].refs[3].handler
                wrapper(nil, vim.fn.json_encode({ key = "val" }))

                assert.stub(on_output).was_called_with({ output = { key = "val" } })
            end)

            it("should call line_output_wrapper and return if format == line", function()
                generator_args.format = "line"
                local generator = helpers.generator_factory(generator_args)
                generator.fn({}, done)

                local wrapper = loop.spawn.calls[1].refs[3].handler
                wrapper(nil, "output")

                assert.stub(on_output).was_called_with("output", { output = "output" })
            end)
        end)
    end)

    describe("formatter_factory", function()
        local opts
        before_each(function()
            stub(helpers, "generator_factory")
            opts = { key = "val" }
        end)

        after_each(function()
            helpers.generator_factory:clear()
            helpers.generator_factory:revert()
        end)

        it("should call generator_factory with enriched opts", function()
            helpers.formatter_factory(opts)

            assert.stub(helpers.generator_factory).was_called_with(opts)
            assert.equals(helpers.generator_factory.calls[1].refs[1].ignore_errors, true)
            assert.truthy(helpers.generator_factory.calls[1].refs[1].on_output)
        end)

        it("should not set ignore_errors when already set", function()
            opts.ignore_errors = false
            helpers.formatter_factory(opts)

            assert.equals(helpers.generator_factory.calls[1].refs[1].ignore_errors, false)
        end)

        describe("on_output", function()
            local formatter_done = stub.new()
            after_each(function()
                formatter_done:clear()
            end)

            it("should call done and return if no output", function()
                helpers.formatter_factory(opts)
                local on_formatter_output = helpers.generator_factory.calls[1].refs[1].on_output

                on_formatter_output({}, formatter_done)

                assert.stub(formatter_done).was_called()
            end)

            it("should call done with edit object", function()
                helpers.formatter_factory(opts)
                local on_formatter_output = helpers.generator_factory.calls[1].refs[1].on_output

                on_formatter_output({
                    output = "new text",
                    content = { "line1", "line" },
                }, formatter_done)

                assert.stub(formatter_done).was_called_with({
                    {
                        row = 0,
                        col = 0,
                        end_row = 2,
                        end_col = -1,
                        text = "new text",
                    },
                })
            end)
        end)
    end)

    describe("make_builtin", function()
        local opts = {
            method = "mockMethod",
            filetypes = { "lua" },
            factory = stub.new(),
            generator_opts = { key = "val", other_key = "other_val" },
        }
        local mock_generator = { fn = function()
            print("I am a generator")
        end }

        local builtin
        before_each(function()
            opts.factory.returns(mock_generator)
            builtin = helpers.make_builtin(opts)
        end)

        after_each(function()
            opts.factory:clear()
        end)

        it("should return builtin with assigned opts", function()
            assert.equals(builtin.method, opts.method)
            assert.equals(builtin.filetypes, opts.filetypes)
            assert.equals(builtin._opts, opts.generator_opts)
        end)

        describe("with", function()
            it("should override filetypes and return", function()
                local result = builtin.with({ filetypes = { "txt" } })

                assert.same(builtin.filetypes, { "txt" })
                assert.equals(result, builtin)
            end)

            it("should override values on opts", function()
                builtin.with({ timeout = 5000 })

                assert.equals(builtin._opts.timeout, 5000)
            end)
        end)

        describe("index metatable", function()
            it("should call factory function with opts and return", function()
                local generator = builtin.generator

                assert.stub(opts.factory).was_called_with(builtin._opts)
                assert.equals(generator, mock_generator)
            end)

            it("should call factory function with override opts", function()
                local result = builtin.with({ timeout = 5000 })

                local _ = result.generator

                assert.equals(opts.factory.calls[1].refs[1].timeout, 5000)
            end)
        end)
    end)
end)
