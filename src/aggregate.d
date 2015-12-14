// Compiler implementation of the D programming language
// Copyright (c) 1999-2015 by Digital Mars
// All Rights Reserved
// written by Walter Bright
// http://www.digitalmars.com
// Distributed under the Boost Software License, Version 1.0.
// http://www.boost.org/LICENSE_1_0.txt

module ddmd.aggregate;

import core.stdc.stdio;
import ddmd.access;
import ddmd.arraytypes;
import ddmd.gluelayer;
import ddmd.clone;
import ddmd.dclass;
import ddmd.declaration;
import ddmd.doc;
import ddmd.dscope;
import ddmd.dstruct;
import ddmd.dsymbol;
import ddmd.dtemplate;
import ddmd.errors;
import ddmd.expression;
import ddmd.func;
import ddmd.globals;
import ddmd.hdrgen;
import ddmd.id;
import ddmd.identifier;
import ddmd.mtype;
import ddmd.opover;
import ddmd.root.outbuffer;
import ddmd.statement;
import ddmd.tokens;
import ddmd.visitor;

enum Sizeok : int
{
    SIZEOKnone,             // size of aggregate is not computed yet
    SIZEOKdone,             // size of aggregate is set correctly
    SIZEOKfwd,              // error in computing size of aggregate
}

alias SIZEOKnone = Sizeok.SIZEOKnone;
alias SIZEOKdone = Sizeok.SIZEOKdone;
alias SIZEOKfwd = Sizeok.SIZEOKfwd;

enum Baseok : int
{
    BASEOKnone,             // base classes not computed yet
    BASEOKin,               // in process of resolving base classes
    BASEOKdone,             // all base classes are resolved
    BASEOKsemanticdone,     // all base classes semantic done
}

alias BASEOKnone = Baseok.BASEOKnone;
alias BASEOKin = Baseok.BASEOKin;
alias BASEOKdone = Baseok.BASEOKdone;
alias BASEOKsemanticdone = Baseok.BASEOKsemanticdone;

/***********************************************************
 */
extern (C++) class AggregateDeclaration : ScopeDsymbol
{
public:
    Type type;
    StorageClass storage_class;
    Prot protection;
    uint structsize;        // size of struct
    uint alignsize;         // size of struct for alignment purposes
    VarDeclarations fields; // VarDeclaration fields
    Sizeok sizeok;          // set when structsize contains valid data
    Dsymbol deferred;       // any deferred semantic2() or semantic3() symbol
    bool isdeprecated;      // true if deprecated

    /* !=null if is nested
     * pointing to the dsymbol that directly enclosing it.
     * 1. The function that enclosing it (nested struct and class)
     * 2. The class that enclosing it (nested class only)
     * 3. If enclosing aggregate is template, its enclosing dsymbol.
     * See AggregateDeclaraton::makeNested for the details.
     */
    Dsymbol enclosing;

    VarDeclaration vthis;   // 'this' parameter if this aggregate is nested

    // Special member functions
    FuncDeclarations invs;          // Array of invariants
    FuncDeclaration inv;            // invariant
    NewDeclaration aggNew;          // allocator
    DeleteDeclaration aggDelete;    // deallocator

    // CtorDeclaration or TemplateDeclaration
    Dsymbol ctor;

    // default constructor - should have no arguments, because
    // it would be stored in TypeInfo_Class.defaultConstructor
    CtorDeclaration defaultCtor;

    Dsymbol aliasthis;      // forward unresolved lookups to aliasthis
    bool noDefaultCtor;     // no default construction

    FuncDeclarations dtors; // Array of destructors
    FuncDeclaration dtor;   // aggregate destructor

    Expression getRTInfo;   // pointer to GC info generated by object.RTInfo(this)

    final extern (D) this(Loc loc, Identifier id)
    {
        super(id);
        this.loc = loc;
        protection = Prot(PROTpublic);
        sizeok = SIZEOKnone; // size not determined yet
    }

    override final void setScope(Scope* sc)
    {
        if (sizeok == SIZEOKdone)
            return;
        ScopeDsymbol.setScope(sc);
    }

    override final void semantic2(Scope* sc)
    {
        //printf("AggregateDeclaration::semantic2(%s) type = %s, errors = %d\n", toChars(), type->toChars(), errors);
        if (!members)
            return;

        if (_scope && sizeok == SIZEOKfwd) // Bugzilla 12531
            semantic(null);
        if (_scope)
        {
            error("has forward references");
            return;
        }

        Scope* sc2 = sc.push(this);
        sc2.stc &= STCsafe | STCtrusted | STCsystem;
        sc2.parent = this;
        //if (isUnionDeclaration())     // TODO
        //    sc2->inunion = 1;
        sc2.protection = Prot(PROTpublic);
        sc2.explicitProtection = 0;
        sc2.structalign = STRUCTALIGN_DEFAULT;
        sc2.userAttribDecl = null;

        for (size_t i = 0; i < members.dim; i++)
        {
            Dsymbol s = (*members)[i];
            //printf("\t[%d] %s\n", i, s->toChars());
            s.semantic2(sc2);
        }

        sc2.pop();
    }

    override final void semantic3(Scope* sc)
    {
        //printf("AggregateDeclaration::semantic3(%s) type = %s, errors = %d\n", toChars(), type.toChars(), errors);
        if (!members)
            return;

        StructDeclaration sd = isStructDeclaration();
        if (!sc) // from runDeferredSemantic3 for TypeInfo generation
        {
            assert(sd);
            sd.semanticTypeInfoMembers();
            return;
        }

        Scope* sc2 = sc.push(this);
        sc2.stc &= STCsafe | STCtrusted | STCsystem;
        sc2.parent = this;
        if (isUnionDeclaration())
            sc2.inunion = 1;
        sc2.protection = Prot(PROTpublic);
        sc2.explicitProtection = 0;
        sc2.structalign = STRUCTALIGN_DEFAULT;
        sc2.userAttribDecl = null;

        for (size_t i = 0; i < members.dim; i++)
        {
            Dsymbol s = (*members)[i];
            s.semantic3(sc2);
        }

        sc2.pop();

        // don't do it for unused deprecated types
        // or error types
        if (!getRTInfo && Type.rtinfo && (!isDeprecated() || global.params.useDeprecated) && (type && type.ty != Terror))
        {
            // Evaluate: RTinfo!type
            auto tiargs = new Objects();
            tiargs.push(type);
            auto ti = new TemplateInstance(loc, Type.rtinfo, tiargs);

            Scope* sc3 = ti.tempdecl._scope.startCTFE();
            sc3.tinst = sc.tinst;
            sc3.minst = sc.minst;
            if (isDeprecated())
                sc3.stc |= STCdeprecated;

            ti.semantic(sc3);
            ti.semantic2(sc3);
            ti.semantic3(sc3);
            auto e = DsymbolExp.resolve(Loc(), sc3, ti.toAlias(), false);

            sc3.endCTFE();

            e = e.ctfeInterpret();
            getRTInfo = e;
        }
        if (sd)
            sd.semanticTypeInfoMembers();
    }

    override final uint size(Loc loc)
    {
        //printf("AggregateDeclaration::size() %s, scope = %p\n", toChars(), scope);
        if (loc.linnum == 0)
            loc = this.loc;
        if (sizeok != SIZEOKdone && _scope)
        {
            semantic(null);

            // Determine the instance size of base class first.
            if (ClassDeclaration cd = isClassDeclaration())
                cd.baseClass.size(loc);
        }

        if (sizeok != SIZEOKdone && members)
        {
            /* See if enough is done to determine the size,
             * meaning all the fields are done.
             */
            struct SV
            {
                /* Returns:
                 *  0       this member doesn't need further processing to determine struct size
                 *  1       this member does
                 */
                extern (C++) static int func(Dsymbol s, void* param)
                {
                    VarDeclaration v = s.isVarDeclaration();
                    if (v)
                    {
                        /* Bugzilla 12799: enum a = ...; is a VarDeclaration and
                         * STCmanifest is already set in parssing stage. So we can
                         * check this before the semantic() call.
                         */
                        if (v.storage_class & STCmanifest)
                            return 0;

                        if (v._scope)
                            v.semantic(null);
                        if (v.storage_class & (STCstatic | STCextern | STCtls | STCgshared | STCmanifest | STCctfe | STCtemplateparameter))
                            return 0;
                        if (v.isField() && v.sem >= SemanticDone)
                            return 0;
                        return 1;
                    }
                    return 0;
                }
            }

            SV sv;
            for (size_t i = 0; i < members.dim; i++)
            {
                Dsymbol s = (*members)[i];
                if (s.apply(&SV.func, &sv))
                    goto L1;
            }
            finalizeSize(null);

        L1:
        }

        if (!members)
        {
            error(loc, "unknown size");
        }
        else if (sizeok != SIZEOKdone)
        {
            error(loc, "no size yet for forward reference");
            //*(char*)0=0;
        }
        return structsize;
    }

    abstract void finalizeSize(Scope* sc);

    /***************************************
     * Calculate field[i].overlapped, and check that all of explicit
     * field initializers have unique memory space on instance.
     * Returns:
     *      true if any errors happen.
     */
    final bool checkOverlappedFields()
    {
        //printf("AggregateDeclaration::checkOverlappedFields() %s\n", toChars());
        assert(sizeok == SIZEOKdone);
        size_t nfields = fields.dim;
        if (isNested())
        {
            auto cd = isClassDeclaration();
            if (!cd || !cd.baseClass || !cd.baseClass.isNested())
                nfields--;
        }
        bool errors = false;

        // Fill in missing any elements with default initializers
        foreach (i; 0 .. nfields)
        {
            auto vd = fields[i];
            if (vd.errors)
                continue;

            auto vx = vd;
            if (vd._init && vd._init.isVoidInitializer())
                vx = null;

            // Find overlapped fields with the hole [vd->offset .. vd->offset->size()].
            foreach (j; 0 .. nfields)
            {
                if (i == j)
                    continue;
                auto v2 = fields[j];
                if (!vd.isOverlappedWith(v2))
                    continue;

                // vd and v2 are overlapping. If either has destructors, postblits, etc., then error
                //printf("overlapping fields %s and %s\n", vd->toChars(), v2->toChars());
                foreach (k; 0 .. 2)
                {
                    auto v = k == 0 ? vd : v2;
                    Type tv = v.type.baseElemOf();
                    Dsymbol sv = tv.toDsymbol(null);
                    if (!sv || errors)
                        continue;
                    StructDeclaration sd = sv.isStructDeclaration();
                    if (sd && (sd.dtor || sd.inv || sd.postblit))
                    {
                        error("destructors, postblits and invariants are not allowed in overlapping fields %s and %s",
                            vd.toChars(), v2.toChars());
                        errors = true;
                        break;
                    }
                }
                vd.overlapped = true;

                if (!vx)
                    continue;
                if (v2._init && v2._init.isVoidInitializer())
                    continue;

                if (vx._init && v2._init)
                {
                    .error(loc, "overlapping default initialization for field %s and %s", v2.toChars(), vd.toChars());
                    errors = true;
                }
            }
        }
        return errors;
    }

    /***************************************
     * Fill out remainder of elements[] with default initializers for fields[].
     * Params:
     *      loc         = location
     *      elements    = explicit arguments which given to construct object.
     *      ctorinit    = true if the elements will be used for default initialization.
     * Returns:
     *      false if any errors occur.
     *      Otherwise, returns true and the missing arguments will be pushed in elements[].
     */
    final bool fill(Loc loc, Expressions* elements, bool ctorinit)
    {
        //printf("AggregateDeclaration::fill() %s\n", toChars());
        assert(sizeok == SIZEOKdone);
        assert(elements);
        size_t nfields = fields.dim - isNested();
        bool errors = false;

        size_t dim = elements.dim;
        elements.setDim(nfields);
        foreach (size_t i; dim .. nfields)
            (*elements)[i] = null;

        // Fill in missing any elements with default initializers
        foreach (i; 0 .. nfields)
        {
            if ((*elements)[i])
                continue;

            auto vd = fields[i];
            auto vx = vd;
            if (vd._init && vd._init.isVoidInitializer())
                vx = null;

            // Find overlapped fields with the hole [vd->offset .. vd->offset->size()].
            size_t fieldi = i;
            foreach (j; 0 .. nfields)
            {
                if (i == j)
                    continue;
                auto v2 = fields[j];
                if (!vd.isOverlappedWith(v2))
                    continue;

                if ((*elements)[j])
                {
                    vx = null;
                    break;
                }
                if (v2._init && v2._init.isVoidInitializer())
                    continue;

                version (all)
                {
                    /* Prefer first found non-void-initialized field
                     * union U { int a; int b = 2; }
                     * U u;    // Error: overlapping initialization for field a and b
                     */
                    if (!vx)
                    {
                        vx = v2;
                        fieldi = j;
                    }
                    else if (v2._init)
                    {
                        .error(loc, "overlapping initialization for field %s and %s", v2.toChars(), vd.toChars());
                        errors = true;
                    }
                }
                else
                {
                    // Will fix Bugzilla 1432 by enabling this path always

                    /* Prefer explicitly initialized field
                     * union U { int a; int b = 2; }
                     * U u;    // OK (u.b == 2)
                     */
                    if (!vx || !vx._init && v2._init)
                    {
                        vx = v2;
                        fieldi = j;
                    }
                    else if (vx != vd && !vx.isOverlappedWith(v2))
                    {
                        // Both vx and v2 fills vd, but vx and v2 does not overlap
                    }
                    else if (vx._init && v2._init)
                    {
                        .error(loc, "overlapping default initialization for field %s and %s",
                            v2.toChars(), vd.toChars());
                        errors = true;
                    }
                    else
                        assert(vx._init || !vx._init && !v2._init);
                }
            }
            if (vx)
            {
                Expression e;
                if (vx.type.size() == 0)
                {
                    e = null;
                }
                else if (vx._init)
                {
                    assert(!vx._init.isVoidInitializer());
                    e = vx.getConstInitializer(false);
                }
                else
                {
                    if ((vx.storage_class & STCnodefaultctor) && !ctorinit)
                    {
                        .error(loc, "field %s.%s must be initialized because it has no default constructor",
                            type.toChars(), vx.toChars());
                        errors = true;
                    }
                    /* Bugzilla 12509: Get the element of static array type.
                     */
                    Type telem = vx.type;
                    if (telem.ty == Tsarray)
                    {
                        /* We cannot use Type::baseElemOf() here.
                         * If the bottom of the Tsarray is an enum type, baseElemOf()
                         * will return the base of the enum, and its default initializer
                         * would be different from the enum's.
                         */
                        while (telem.toBasetype().ty == Tsarray)
                            telem = (cast(TypeSArray)telem.toBasetype()).next;
                        if (telem.ty == Tvoid)
                            telem = Type.tuns8.addMod(telem.mod);
                    }
                    if (telem.needsNested() && ctorinit)
                        e = telem.defaultInit(loc);
                    else
                        e = telem.defaultInitLiteral(loc);
                }
                (*elements)[fieldi] = e;
            }
        }
        foreach (e; *elements)
        {
            if (e && e.op == TOKerror)
                return false;
        }

        return !errors;
    }

    /****************************
     * Do byte or word alignment as necessary.
     * Align sizes of 0, as we may not know array sizes yet.
     *
     * alignment: struct alignment that is in effect
     * size: alignment requirement of field
     */
    final static void alignmember(structalign_t alignment, uint size, uint* poffset)
    {
        //printf("alignment = %d, size = %d, offset = %d\n",alignment,size,offset);
        switch (alignment)
        {
        case cast(structalign_t)1:
            // No alignment
            break;

        case cast(structalign_t)STRUCTALIGN_DEFAULT:
            // Alignment in Target::fieldalignsize must match what the
            // corresponding C compiler's default alignment behavior is.
            assert(size > 0 && !(size & (size - 1)));
            *poffset = (*poffset + size - 1) & ~(size - 1);
            break;

        default:
            // Align on alignment boundary, which must be a positive power of 2
            assert(alignment > 0 && !(alignment & (alignment - 1)));
            *poffset = (*poffset + alignment - 1) & ~(alignment - 1);
            break;
        }
    }

    /****************************************
     * Place a member (mem) into an aggregate (agg), which can be a struct, union or class
     * Returns:
     *      offset to place field at
     *
     * nextoffset:    next location in aggregate
     * memsize:       size of member
     * memalignsize:  size of member for alignment purposes
     * alignment:     alignment in effect for this member
     * paggsize:      size of aggregate (updated)
     * paggalignsize: size of aggregate for alignment purposes (updated)
     * isunion:       the aggregate is a union
     */
    final static uint placeField(uint* nextoffset, uint memsize, uint memalignsize,
        structalign_t alignment, uint* paggsize, uint* paggalignsize, bool isunion)
    {
        uint ofs = *nextoffset;
        alignmember(alignment, memalignsize, &ofs);
        uint memoffset = ofs;
        ofs += memsize;
        if (ofs > *paggsize)
            *paggsize = ofs;
        if (!isunion)
            *nextoffset = ofs;

        if (alignment == STRUCTALIGN_DEFAULT)
        {
            if (global.params.is64bit && memalignsize == 16)
            {
            }
            else if (8 < memalignsize)
                memalignsize = 8;
        }
        else
        {
            if (memalignsize < alignment)
                memalignsize = alignment;
        }

        if (*paggalignsize < memalignsize)
            *paggalignsize = memalignsize;

        return memoffset;
    }

    override final Type getType()
    {
        return type;
    }

    // is aggregate deprecated?
    override final bool isDeprecated()
    {
        return isdeprecated;
    }

    /****************************************
     * Returns true if there's an extra member which is the 'this'
     * pointer to the enclosing context (enclosing aggregate or function)
     */
    final bool isNested()
    {
        return enclosing !is null;
    }

    final void makeNested()
    {
        if (enclosing) // if already nested
            return;
        if (sizeok == SIZEOKdone)
            return;
        if (isUnionDeclaration() || isInterfaceDeclaration())
            return;
        if (storage_class & STCstatic)
            return;

        // If nested struct, add in hidden 'this' pointer to outer scope
        auto s = toParent2();
        if (!s)
            return;
        Type t = null;
        if (auto fd = s.isFuncDeclaration())
        {
            enclosing = fd;

            /* Bugzilla 14422: If a nested class parent is a function, its
             * context pointer (== `outer`) should be void* always.
             */
            t = Type.tvoidptr;
        }
        else if (auto ad = s.isAggregateDeclaration())
        {
            if (isClassDeclaration() && ad.isClassDeclaration())
            {
                enclosing = ad;
            }
            else if (isStructDeclaration())
            {
                if (auto ti = ad.parent.isTemplateInstance())
                {
                    enclosing = ti.enclosing;
                }
            }
            t = ad.handleType();
        }
        if (enclosing)
        {
            //printf("makeNested %s, enclosing = %s\n", toChars(), enclosing->toChars());
            assert(t);
            if (t.ty == Tstruct)
                t = Type.tvoidptr; // t should not be a ref type
            assert(!vthis);
            vthis = new ThisDeclaration(loc, t);
            //vthis->storage_class |= STCref;
            members.push(vthis);
        }
    }

    override final bool isExport()
    {
        return protection.kind == PROTexport;
    }

    /*******************************************
     * Look for constructor declaration.
     */
    final Dsymbol searchCtor()
    {
        Dsymbol s = search(Loc(), Id.ctor);
        if (s)
        {
            if (!(s.isCtorDeclaration() ||
                  s.isTemplateDeclaration() ||
                  s.isOverloadSet()))
            {
                s.error("is not a constructor; identifiers starting with __ are reserved for the implementation");
                errors = true;
                s = null;
            }
        }
        return s;
    }

    override final Prot prot()
    {
        return protection;
    }

    // 'this' type
    final Type handleType()
    {
        return type;
    }

    // Back end
    Symbol* stag; // tag symbol for debug data
    Symbol* sinit;

    override final AggregateDeclaration isAggregateDeclaration()
    {
        return this;
    }

    override void accept(Visitor v)
    {
        v.visit(this);
    }
}
