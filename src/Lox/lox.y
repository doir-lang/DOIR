%{
	int yylex(reflex::Input* input = nullptr);
	int yyparse();
	void yyerror(const char* s);
	#define YYSTYPE ecs::Entity
%}

%token IDENTIFIER
%token NUMBER
%token STRING
%token True False Null
%token CLASS FUN VAR FOR IF ELSE PRINT RETURN WHILE OR AND THIS SUPER
%token NOT_EQUAL EQUAL GREATER_EQUAL LESS_EQUAL
%left '{' '}' '[' ']'
%left ','
%left ':'


%%


START: program;
program: declaration | declaration program;
declaration: classDecl | funDecl | varDecl | statement;

classDecl: CLASS { yyerror("Classes not supported!"); YYERROR; } IDENTIFIER classDeclTail;
classDeclTail: '<' IDENTIFIER '{' functionList '}' | '{' functionList '}';
functionList: function | function functionList;
funDecl: FUN function;
varDecl: VAR IDENTIFIER varDeclTail {
	$$ = $2;
	auto& lexeme2 = $$.get_component<doir::comp::lexeme>();
	get_key_and_mark_occupied($$.add_component<Module::HashtableComponent<variable_declare>>()) = {lexeme2, blocks.back()};
	$$.add_component<interpreter::skippable>();
	current_block().push_back_child(*module, $$);

	if($3) {
		auto lookup = ecs::Entity::create(*module);
		lookup.add_component<doir::comp::lexeme>() = lexeme2;
		lookup.add_component<variable>();
		lookup.add_component<doir::entity_reference>().lexeme = lexeme2;

		auto assignment = ecs::Entity::create(*module);
		assignment.add_component<doir::comp::lexeme>() = lexeme2 + $3.get_component<doir::comp::lexeme>();
		assignment.add_component<assign>();
		assignment.add_component<operation>() = {lookup, $3};
		current_block().push_back_child(*module, assignment);
	}
};
varDeclTail: '=' expression ';' { $$ = $2; } | ';' { $$ = 0; };

statement: exprStmt
| forStmt
| ifStmt
| printStmt
| returnStmt
| whileStmt
| block;

exprStmt: expression ';' { $$ = $1; current_block().push_back_child(*module, $$); };

forStmt: FOR '(' forStmtContentFirst forStmtContent forStmtContentLast ')' statement {
	current_block().pop_back_child(*module);
	auto $$ = ecs::Entity::create(*module);
	auto& lexeme = $$.add_component<doir::comp::lexeme>() = $7.get_component<doir::comp::lexeme>();
	if($5) lexeme = $5.get_component<doir::comp::lexeme>() + lexeme;
	if($4) lexeme = $4.get_component<doir::comp::lexeme>() + lexeme;
	if($3) lexeme = $3.get_component<doir::comp::lexeme>() + lexeme;
	// if($$ != $$) $$.add_component<doir::comp::lexeme>() = lexeme;
	$$.add_component<while_>();
	$$.add_component<operation>() = {$4, $7};
	current_block().push_back_child(*module, $$);
	if($5) {
		auto innerBlock = ecs::Entity::create(*module);
		$$.get_component<operation>().b = innerBlock;
		innerBlock.add_component<doir::comp::lexeme>() = $5.get_component<doir::comp::lexeme>() + $7.get_component<doir::comp::lexeme>();
		auto& block = innerBlock.add_component<struct block>();
		block.push_back_child(*module, $7);
		block.push_back_child(*module, $5);
		add_body_marker(innerBlock, $$);
	} else add_body_marker($$);
};
forStmtContentFirst: varDecl { $$ = $1; } | exprStmt { $$ = $1; } | ';' { $$ = 0; };
forStmtContent: exprStmt { $$ = $1; current_block().pop_back_child(*module); } | ';' { $$ = 0; };
forStmtContentLast: expression { $$ = $1; } | { $$ = 0; };

ifStmt: IF '(' expression ')' statement { current_block().pop_back_child(*module); } ifStmtTail {
	$$ = ecs::Entity::create(*module);
	auto& lexeme = $$.add_component<doir::comp::lexeme>() = $3.get_component<doir::comp::lexeme>() + $5.get_component<doir::comp::lexeme>();
	if($7) lexeme = lexeme + $7.get_component<doir::comp::lexeme>();
	$$.add_component<if_>();
	auto& op = $$.add_component<operation>() = {$3, $5, $7};
	auto last = $7 ? $7 : $5;
	if(!last.has_component<block>()) {
		auto marker_block = ecs::Entity::create(*module);
		marker_block.add_component<doir::comp::lexeme>() = last.get_component<doir::comp::lexeme>();
		marker_block.add_component<block>().push_back_child(*module, last);
		add_body_marker(marker_block, $$);
		if($7) op.c = marker_block;
		else op.b = marker_block;
	} else add_body_marker(last, $$);
	current_block().push_back_child(*module, $$);
};
ifStmtTail: ELSE statement { $$ = $2; current_block().pop_back_child(*module); } | { $$ = 0; };

printStmt: PRINT expression ';' {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<print>();
	$$.add_component<operation>() = {$2};
	current_block().push_back_child(*module, $$);
};
returnStmt: RETURN expression ';' {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<return_>();
	$$.add_component<operation>() = {$2};
	current_block().push_back_child(*module, $$);
} | RETURN ';' {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<return_>();
	current_block().push_back_child(*module, $$);
};
whileStmt: WHILE '(' expression ')' statement {
	current_block().pop_back_child(*module);
	auto& lexeme5 = $5.get_component<doir::comp::lexeme>();
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $3.get_component<doir::comp::lexeme>() + lexeme5;
	$$.add_component<while_>();
	if($5.has_component<block>())
		add_body_marker($5);
	else {
		auto blockE = ecs::Entity::create(*module);
		blockE.add_component<doir::comp::lexeme>() = lexeme5;
		auto& block = blockE.add_component<struct block>();
		add_body_marker(blockE);
		block.push_back_child(*module, $5);
		$5 = blockE;
	}
	$$.add_component<operation>() = {$3, $5};
	current_block().push_back_child(*module, $$);
};
block: '{' {
	auto dbg = $$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = {location, 1};
	$$.add_component<block>();
	$$.add_component<interpreter::skippable>();
	blocks.push_back($$);
} declarationList '}' { $$ = blocks.pop_back(); }
| '{' '}' {
	auto dbg = $$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = {location - 1, 1};
	$$.add_component<block>();
	$$.add_component<interpreter::skippable>();
};
declarationList: declaration | declaration declarationList;

expression: assignment { $$ = $1; };

assignment: call '.' { yyerror("Classes not supported!"); YYERROR; } IDENTIFIER '=' assignment
| identifier '=' assignment {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $1.get_component<doir::comp::lexeme>() + $3.get_component<doir::comp::lexeme>();
	$$.add_component<assign>();
	$$.add_component<operation>() = {$1, $3};
} | logic_or { $$ = $1; };

logic_or: logic_and logic_orTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = objects.pop_back();

		$2.get_component<operation>().a = $1;
		auto& lexeme = $2.get_component<doir::comp::lexeme>();
		lexeme = $1.get_component<doir::comp::lexeme>() + lexeme;
	}
};
logic_orTail: OR logic_and logic_orTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<or_>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | { $$ = 0; };

logic_and: equality logic_andTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = objects.pop_back();

		$2.get_component<operation>().a = $1;
		auto& lexeme = $2.get_component<doir::comp::lexeme>();
		lexeme = $1.get_component<doir::comp::lexeme>() + lexeme;
	}
};
logic_andTail: AND equality logic_andTail {
	$$ = module->create_entity();
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<and_>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | { $$ = 0; };

equality: comparison equalityTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = objects.pop_back();

		$2.get_component<operation>().a = $1;
		auto& lexeme = $2.get_component<doir::comp::lexeme>();
		lexeme = $1.get_component<doir::comp::lexeme>() + lexeme;
	}
};
equalityTail: NOT_EQUAL comparison equalityTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<not_equal_to>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | EQUAL comparison equalityTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<equal_to>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | { $$ = 0; };

comparison: term comparisonTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = objects.pop_back();

		$2.get_component<operation>().a = $1;
		auto& lexeme = $2.get_component<doir::comp::lexeme>();
		lexeme = $1.get_component<doir::comp::lexeme>() + lexeme;
	}
};
comparisonTail: '>' term comparisonTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<greater_than>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | GREATER_EQUAL term comparisonTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<greater_than_equal_to>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | '<' term comparisonTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<less_than>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | LESS_EQUAL term comparisonTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<less_than_equal_to>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | { $$ = 0; };

term: factor termTail {
	if($2 == 0)
		$$ = $1;
	else {
		auto dbg = $$ = objects.pop_back();

		$2.get_component<operation>().a = $1;
		auto& lexeme = $2.get_component<doir::comp::lexeme>();
		lexeme = $1.get_component<doir::comp::lexeme>() + lexeme;
	}
};
termTail: '-' factor termTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<subtract>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | '+' factor termTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<add>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | { $$ = 0; };

factor: unary factorTail {
	if($2 == 0)
		$$ = $1;
	else {
		auto dbg = $$ = objects.pop_back();

		$2.get_component<operation>().a = $1;
		auto& lexeme = $2.get_component<doir::comp::lexeme>();
		lexeme = $1.get_component<doir::comp::lexeme>() + lexeme;
	}
};
factorTail: '/' unary factorTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<divide>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | '*' unary factorTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<multiply>();
	$$.add_component<operation>() = {0, $2};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<operation>().a = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
} | { $$ = 0; };

unary: '!' unary {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<not_>();
	$$.add_component<operation>() = {$2};
} | '-' unary {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = $2.get_component<doir::comp::lexeme>();
	$$.add_component<negate>();
	$$.add_component<operation>() = {$2};
} | call { $$ = $1; };

call: primary callTail {
	if($2 == 0)
		$$ = $1;
	else {
		auto dbg = $$ = objects.pop_back();

		$2.get_component<call>().parent = $1;
		auto& lexeme = $2.get_component<doir::comp::lexeme>();
		lexeme = $1.get_component<doir::comp::lexeme>() + lexeme;
	}
};
callTail: '(' ')' callTail {
	$$ = ecs::Entity::create(*module);
	$$.add_component<doir::comp::lexeme>() = {location - 1, 2};
	$$.add_component<call>() = {block{.parent = 0}};
	if($3 == 0)
		objects.push_back($$);
	else {
		$3.get_component<call>().parent = $$;
		auto& lexeme = $3.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
}
| '(' { $$ = objects.size(); } arguments ')' callTail {
	auto end_size = $2.entity;
	$$ = ecs::Entity::create(*module);
	auto& call = $$.add_component<struct call>() = {block{.parent = 0}};
	while(objects.size() > end_size)
		call.push_back_child(*module, objects.pop_back());
	// call.finalize_list(*module);
	$$.add_component<doir::comp::lexeme>() = call.children.next.get_component<doir::comp::lexeme>() 
		+ call.children_end.get_component<doir::comp::lexeme>();

	if($5 == 0)
		objects.push_back($$);
	else {
		$5.get_component<struct call>().parent = $$;
		auto& lexeme = $5.get_component<doir::comp::lexeme>();
		lexeme = $$.get_component<doir::comp::lexeme>() + lexeme;
	}
}
| '.' { yyerror("Classes not supported!"); YYERROR; } IDENTIFIER callTail { $$ = 0; } | { $$ = 0; };

primary: True { $$ = $1; }
| False { $$ = $1; }
| Null { $$ = $1; }
| THIS { yyerror("Classes (this) not supported!"); YYERROR; }
| NUMBER { $$ = $1; }
| STRING { $$ = $1; }
| identifier { $$ = $1; } 
| '(' expression ')' { $$ = $2; }
| SUPER { yyerror("Classes (super) not supported!"); YYERROR; } '.' IDENTIFIER;

identifier: IDENTIFIER {
	$$ = $1;
	$$.add_component<variable>();
	$$.add_component<doir::entity_reference>().lexeme = $$.get_component<doir::lexeme>();
};

function: IDENTIFIER '(' ')' block {
	auto dbg = $$ = $4;
	auto& decl = get_key_and_mark_occupied($$.add_component<Module::HashtableComponent<function_declare>>())
		= {declare{.name = $1.get_component<doir::comp::lexeme>(), .parent = blocks.back()}};
	auto& lexeme = $$.get_component<doir::comp::lexeme>();
	lexeme = decl.name + lexeme;
	$$.add_component<interpreter::skippable>();
	current_block().push_back_child(*module, $$);
	add_body_marker($$);
} | IDENTIFIER '(' {module->add_component<parameters>($1); objects.push_back($1);} parameters ')' block {
	auto dbg = $$ = $6;
	auto& decl = get_key_and_mark_occupied($$.add_component<Module::HashtableComponent<function_declare>>())
		= {declare{.name = $1.get_component<doir::comp::lexeme>(), .parent = blocks.back()}};
	auto& lexeme = $$.get_component<doir::comp::lexeme>();
	lexeme = decl.name + lexeme;
	auto& oldParams = $1.get_component<parameters>();
	$$.add_component<parameters>() = oldParams;
	oldParams = {ecs::invalid_entity, ecs::invalid_entity};
	$$.add_component<interpreter::skippable>();
	current_block().push_back_child(*module, $$);
	add_body_marker($$);
};
parameters: IDENTIFIER {
	auto func = objects.back();
	get_key_and_mark_occupied($1.add_component<Module::HashtableComponent<parameter_declare>>())
		= {declare{.name = $1.get_component<doir::comp::lexeme>(), .parent = func}};
	auto& params = func.get_component<parameters>();
	$$.add_component<interpreter::skippable>();
	params.push_back(*module, $1);
} parametersTail;
parametersTail: ',' IDENTIFIER {
	auto func = objects.back();
	get_key_and_mark_occupied($2.add_component<Module::HashtableComponent<parameter_declare>>())
		= {declare{.name = $2.get_component<doir::comp::lexeme>(), .parent = func}};
	auto& params = func.get_component<parameters>();
	params.push_back(*module, $2);
	$$.add_component<interpreter::skippable>();
} parametersTail | { $$ = 0; };

arguments: expression argumentsTail { objects.push_back($1); };
argumentsTail: ',' expression argumentsTail { objects.push_back($2); } | { $$ = 0; };

%%

void yyerror(const char* s) {
	nowide::cerr << s << std::endl;
}